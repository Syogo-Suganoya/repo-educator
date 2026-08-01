import asyncio
import logging
import time

from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse

from app import analysis_cache, github_app, store
from app.analysis_cache import AnalysisResult
from app.auth import AuthUser, optional_user, require_user
from app.config import settings
from app.github_client import (
    RateLimitedError,
    RepositoryAccessDeniedError,
    RepositoryNotFoundError,
    RepositoryRef,
    fetch_repository_files,
    fetch_repository_meta,
    parse_repository_url,
    resolve_commit_sha,
)
from app.doc_generator import generate_docs
from app.quiz_generator import generate_quizzes
from app.sample_docs import get_sample_docs
from app.sample_quizzes import get_sample_sections
from app.schemas import (
    AnswerRequest,
    InstallUrlResponse,
    LinkGithubRequest,
    LinkGithubResponse,
    MeResponse,
    ProgressResponse,
    QuizGenerateRequest,
    QuizGenerateResponse,
    RepositoryListResponse,
    RepositorySummary,
)

logger = logging.getLogger(__name__)

app = FastAPI(title="repo-educator API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


# --- クイズ生成 -----------------------------------------------------------


@app.post("/api/v1/quiz/generate", response_model=QuizGenerateResponse)
async def generate_quiz(
    request: QuizGenerateRequest,
    user: AuthUser | None = Depends(optional_user),
) -> QuizGenerateResponse:
    """認証は任意。未ログインでも公開リポジトリはこれまで通り学習できる。"""
    try:
        owner, repo = parse_repository_url(request.repository_url)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e

    if not settings.vertex_ai_configured:
        sample_sections = get_sample_sections(owner, repo)
        if sample_sections is not None:
            return QuizGenerateResponse(
                repository_id=f"{owner}_{repo}_{request.branch}",
                url=request.repository_url,
                sections=sample_sections,
                docs=get_sample_docs(owner, repo) or [],
            )

    # ログイン済みなら、そのユーザーのインストールから当該リポジトリ用のトークンを発行する。
    installation_token: str | None = None
    if user is not None and github_app.app_configured():
        installation_ids = store.get_installations(user.uid)
        if installation_ids:
            installation_token = await github_app.find_installation_token_for_repo(
                installation_ids, owner, repo
            )

    # まずリポジトリの最終push時刻だけを見る（GitHub API 1回）。
    # 前回と変化がなければ、コミットSHAの問い合わせもソースの取得も省ける。
    try:
        ref = await _resolve_ref(owner, repo, request.branch, installation_token)
    except RepositoryNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    except RepositoryAccessDeniedError as e:
        raise HTTPException(status_code=403, detail=str(e)) from e
    except RateLimitedError as e:
        raise HTTPException(status_code=429, detail=_rate_limit_message(e)) from e

    key = analysis_cache.cache_key(owner, repo, ref.commit_sha)
    repository_id = key
    caller_has_access = installation_token is not None

    cached = _lookup_cache(owner, repo, ref.commit_sha, key)
    if cached is not None:
        _ensure_can_read(cached, caller_has_access=caller_has_access)
        sections = cached.sections_for(request.num_questions)
        if sections is not None:
            return QuizGenerateResponse(
                repository_id=repository_id,
                url=request.repository_url,
                sections=sections,
                docs=cached.docs,
                cached=True,
            )

    # ここから先はGitHubのダウンロードとGeminiの呼び出しが走る。
    # 同じリポジトリへの同時リクエストは1本にまとめ、結果を共有する。
    async def build() -> AnalysisResult:
        return await _analyze(
            ref=ref,
            branch=request.branch,
            token=installation_token,
            url=request.repository_url,
            num_questions=request.num_questions,
            focus_language=request.focus_language,
            known=cached,
        )

    try:
        result = await analysis_cache.run_once(f"{key}:{request.num_questions}", build)
    except RepositoryNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    except RepositoryAccessDeniedError as e:
        raise HTTPException(status_code=403, detail=str(e)) from e
    except RateLimitedError as e:
        raise HTTPException(status_code=429, detail=_rate_limit_message(e)) from e

    # 生成を待っている間に権限が変わっている可能性もあるので、返す直前にも確認する。
    _ensure_can_read(result, caller_has_access=caller_has_access)

    return QuizGenerateResponse(
        repository_id=repository_id,
        url=request.repository_url,
        sections=result.sections_for(request.num_questions) or [],
        docs=result.docs,
        cached=False,
    )


def _rate_limit_message(error: RateLimitedError) -> str:
    """レートリミットの解除時刻を分単位で伝える。

    未認証は60req/hしかないため、GITHUB_TOKEN の設定を促す一文も添える。
    """
    if error.reset_epoch:
        minutes = max(1, (error.reset_epoch - int(time.time()) + 59) // 60)
        return f"GitHub API rate limit exceeded. Retry in about {minutes} minute(s)."
    return "GitHub API rate limit exceeded. Please retry later."


async def _resolve_ref(
    owner: str, repo: str, branch: str, token: str | None
) -> RepositoryRef:
    """対象コミットを決める。GitHubへの問い合わせを最小限に抑える。

      1. リポジトリ情報を取得（1回）… private と pushed_at
      2. 前回見た pushed_at と同じなら、記録済みのコミットSHAをそのまま使う
      3. 違えば（または記録がなければ）コミットSHAを問い合わせる（1回）

    pushed_at はリポジトリ全体の値で、別ブランチへのpushでも進む。
    そのため「進んでいたら再生成」ではなく「進んでいたらSHAを確認する」に留める。
    SHAが同じなら解析結果はそのまま再利用される。
    """
    meta = await fetch_repository_meta(owner, repo, branch, token)
    hkey = analysis_cache.head_key(owner, repo, branch)

    known = analysis_cache.head_memory_get(hkey) or store.get_head(owner, repo, branch)
    if analysis_cache.is_unchanged(known, meta.pushed_at):
        logger.info("No push since last check; reusing commit %s", known.commit_sha[:8])
        return RepositoryRef(
            owner=owner, repo=repo, commit_sha=known.commit_sha, private=meta.private
        )

    commit_sha = await resolve_commit_sha(owner, repo, branch, token)
    head = analysis_cache.HeadRef(commit_sha=commit_sha, pushed_at=meta.pushed_at)
    analysis_cache.head_memory_put(hkey, head)
    store.save_head(owner, repo, branch, head)

    if known is not None and known.commit_sha == commit_sha:
        # 他のブランチへのpushだった。対象ブランチは動いていないので再生成は不要。
        logger.info("Push detected but %s is unchanged; reusing analysis", branch)

    return RepositoryRef(owner=owner, repo=repo, commit_sha=commit_sha, private=meta.private)


def _lookup_cache(
    owner: str, repo: str, commit_sha: str, key: str
) -> AnalysisResult | None:
    """メモリ → Firestore の順にキャッシュを探す。"""
    hit = analysis_cache.memory_get(key)
    if hit is not None:
        logger.info("Analysis cache hit (memory): %s", key)
        return hit

    hit = store.get_cached_analysis(owner, repo, commit_sha)
    if hit is not None:
        logger.info("Analysis cache hit (firestore): %s", key)
        # 次回以降はFirestoreの読み取りも省けるようメモリにも載せる。
        analysis_cache.memory_put(key, hit)
    return hit


def _ensure_can_read(result: AnalysisResult, *, caller_has_access: bool) -> None:
    """privateリポジトリの解析結果は、いま実際にアクセス権がある場合のみ返す。

    ユーザーごとにキャッシュを分けるのではなく都度確認する方式にしているのは、
    GitHub側でインストールを外された後もキャッシュが返り続ける事故を防ぐため。
    ドキュメントはクイズと違い生のコードを原文のまま引用するので、ここは緩めない。
    """
    if result.private and not caller_has_access:
        raise HTTPException(
            status_code=403,
            detail="You no longer have access to this repository",
        )


async def _analyze(
    *,
    ref: RepositoryRef,
    branch: str,
    token: str | None,
    url: str,
    num_questions: int,
    focus_language: str | None,
    known: AnalysisResult | None,
) -> AnalysisResult:
    """不足している分だけを生成し、キャッシュに書き戻す。

    ドキュメントは出題数に依存しないため、既にキャッシュがあれば再生成しない。
    「同じリポジトリを別の出題数で開いただけ」でドキュメントまで作り直すのを避ける。
    """
    files = await fetch_repository_files(ref, branch, token)

    needs_docs = known is None or not known.docs
    if needs_docs:
        sections, docs = await asyncio.gather(
            generate_quizzes(files, num_questions, focus_language),
            generate_docs(files, focus_language),
        )
    else:
        sections = await generate_quizzes(files, num_questions, focus_language)
        docs = known.docs

    result = AnalysisResult(
        private=ref.private,
        docs=docs,
        sections_by_count={
            **(known.sections_by_count if known else {}),
            num_questions: sections,
        },
    )

    key = analysis_cache.cache_key(ref.owner, ref.repo, ref.commit_sha)
    analysis_cache.memory_put(key, result)
    store.save_cached_analysis(ref.owner, ref.repo, ref.commit_sha, url=url, result=result)
    return result


# --- アカウント / GitHub連携 ----------------------------------------------


@app.get("/api/v1/me", response_model=MeResponse)
async def me(user: AuthUser = Depends(require_user)) -> MeResponse:
    store.upsert_user(user.uid, email=user.email, name=user.name)
    stored = store.get_user(user.uid) or {}
    return MeResponse(
        uid=user.uid,
        email=user.email,
        name=user.name,
        picture=user.picture,
        github_login=stored.get("github_login"),
        installation_count=len(stored.get("installations", [])),
        github_app_available=github_app.app_configured(),
    )


@app.post("/api/v1/github/link", response_model=LinkGithubResponse)
async def link_github(
    request: LinkGithubRequest,
    user: AuthUser = Depends(require_user),
) -> LinkGithubResponse:
    """サインイン直後のGitHubユーザートークンを受け取り、インストール一覧を同期する。

    トークンはKMSで暗号化してから保存する（用途は再ログインなしの一覧再取得のみ）。
    """
    store.upsert_user(user.uid, email=user.email, name=user.name)
    store.save_github_user_token(user.uid, request.github_access_token)

    installations = await github_app.list_user_installations(request.github_access_token)
    installation_ids = [int(i["id"]) for i in installations if i.get("id")]
    github_login = next(
        (i.get("account", {}).get("login") for i in installations if i.get("account")), None
    )
    store.set_installations(user.uid, installation_ids, github_login=github_login)

    return LinkGithubResponse(
        installation_count=len(installation_ids), github_login=github_login
    )


@app.get("/api/v1/github/install-url", response_model=InstallUrlResponse)
async def install_url(user: AuthUser = Depends(require_user)) -> InstallUrlResponse:
    try:
        return InstallUrlResponse(install_url=github_app.build_install_url(user.uid))
    except github_app.GitHubAppNotConfiguredError as e:
        raise HTTPException(status_code=503, detail="GitHub App is not configured") from e


@app.get("/api/v1/github/setup-callback")
async def setup_callback(installation_id: int | None = None, state: str | None = None):
    """GitHub App インストール完了後にGitHubからリダイレクトされてくる。

    ブラウザからの遷移なのでIDトークンを載せられない。代わりに install-url で
    発行した署名付きstateからuidを復元して紐付ける。
    """
    redirect_base = settings.frontend_redirect_base

    if not installation_id or not state:
        return RedirectResponse(f"{redirect_base}?install=failed")

    uid = github_app.verify_state(state)
    if uid is None:
        logger.warning("Rejected setup-callback with an invalid or expired state")
        return RedirectResponse(f"{redirect_base}?install=failed")

    store.add_installation(uid, installation_id)
    return RedirectResponse(f"{redirect_base}?install=success")


@app.get("/api/v1/repositories", response_model=RepositoryListResponse)
async def list_repositories(user: AuthUser = Depends(require_user)) -> RepositoryListResponse:
    """GitHub App で許可されたリポジトリ一覧（リポジトリ選択UI用）。"""
    if not github_app.app_configured():
        raise HTTPException(status_code=503, detail="GitHub App is not configured")

    repositories: list[RepositorySummary] = []
    for installation_id in store.get_installations(user.uid):
        try:
            found = await github_app.list_installation_repositories(installation_id)
        except github_app.GitHubAppNotConfiguredError:
            continue
        for repository in found:
            repositories.append(
                RepositorySummary(
                    full_name=repository["full_name"],
                    html_url=repository["html_url"],
                    default_branch=repository.get("default_branch", "main"),
                    private=bool(repository.get("private")),
                    description=repository.get("description"),
                    language=repository.get("language"),
                )
            )

    repositories.sort(key=lambda r: r.full_name)
    return RepositoryListResponse(repositories=repositories)


# --- 学習履歴 -------------------------------------------------------------


@app.post("/api/v1/progress/answer")
async def record_answer(
    request: AnswerRequest,
    user: AuthUser = Depends(require_user),
) -> dict[str, str]:
    store.record_answer(user.uid, request.repository_id, request.correct)
    return {"status": "ok"}


@app.get("/api/v1/progress", response_model=ProgressResponse)
async def get_progress(user: AuthUser = Depends(require_user)) -> ProgressResponse:
    raw = store.get_progress(user.uid)
    return ProgressResponse(
        learning_progress={
            repository_id: {
                "total_answered": entry.get("total_answered", 0),
                "correct_count": entry.get("correct_count", 0),
            }
            for repository_id, entry in raw.items()
        }
    )
