import asyncio
import logging
import time

from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from app import analysis_cache, store
from app.analysis_cache import AnalysisResult
from app.auth import (
    AuthUser,
    create_access_token,
    hash_password,
    optional_user,
    require_user,
    verify_password,
)
from app.config import settings
from app.db import init_models
from app.github_client import (
    InvalidTokenError,
    RateLimitedError,
    RepositoryAccessDeniedError,
    RepositoryNotFoundError,
    RepositoryRef,
    fetch_repository_files,
    fetch_repository_meta,
    list_my_repositories,
    parse_repository_url,
    resolve_commit_sha,
    verify_user_token,
)
from app.doc_generator import generate_docs
from app.quiz_generator import generate_quizzes
from app.sample_docs import get_sample_docs
from app.sample_quizzes import get_sample_sections
from app.schemas import (
    AnswerRequest,
    AuthResponse,
    GithubTokenStatusResponse,
    LoginRequest,
    MeResponse,
    ProgressResponse,
    QuizGenerateRequest,
    QuizGenerateResponse,
    RegisterRequest,
    RepositoryListResponse,
    RepositorySummary,
    SaveGithubTokenRequest,
)

logger = logging.getLogger(__name__)

app = FastAPI(title="repo-educator API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def _on_startup() -> None:
    await init_models()


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

    if not settings.gemini_configured:
        sample_sections = get_sample_sections(owner, repo)
        if sample_sections is not None:
            return QuizGenerateResponse(
                repository_id=f"{owner}_{repo}_{request.branch}",
                url=request.repository_url,
                sections=sample_sections,
                docs=get_sample_docs(owner, repo) or [],
            )

    # ログイン済みなら、本人が設定画面で保存したPATを使う（サーバ共有の環境変数とは別物）。
    user_token: str | None = None
    if user is not None:
        user_token = await store.load_github_user_token(user.uid)

    # まずリポジトリの最終push時刻だけを見る（GitHub API 1回）。
    # 前回と変化がなければ、コミットSHAの問い合わせもソースの取得も省ける。
    try:
        ref = await _resolve_ref(owner, repo, request.branch, user_token)
    except RepositoryNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    except RepositoryAccessDeniedError as e:
        raise HTTPException(status_code=403, detail=str(e)) from e
    except RateLimitedError as e:
        raise HTTPException(status_code=429, detail=_rate_limit_message(e)) from e

    key = analysis_cache.cache_key(owner, repo, ref.commit_sha)
    repository_id = key
    caller_has_access = user_token is not None

    cached = await _lookup_cache(owner, repo, ref.commit_sha, key)
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
            token=user_token,
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

    未認証は60req/hしかない。ログインして自分のPATを設定画面から登録すると
    5,000req/hになるため、フロント側はこの案内と合わせてトークン入力欄へ誘導できる。
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

    known = analysis_cache.head_memory_get(hkey) or await store.get_head(owner, repo, branch)
    if analysis_cache.is_unchanged(known, meta.pushed_at):
        logger.info("No push since last check; reusing commit %s", known.commit_sha[:8])
        return RepositoryRef(
            owner=owner, repo=repo, commit_sha=known.commit_sha, private=meta.private
        )

    commit_sha = await resolve_commit_sha(owner, repo, branch, token)
    head = analysis_cache.HeadRef(commit_sha=commit_sha, pushed_at=meta.pushed_at)
    analysis_cache.head_memory_put(hkey, head)
    await store.save_head(owner, repo, branch, head)

    if known is not None and known.commit_sha == commit_sha:
        # 他のブランチへのpushだった。対象ブランチは動いていないので再生成は不要。
        logger.info("Push detected but %s is unchanged; reusing analysis", branch)

    return RepositoryRef(owner=owner, repo=repo, commit_sha=commit_sha, private=meta.private)


async def _lookup_cache(
    owner: str, repo: str, commit_sha: str, key: str
) -> AnalysisResult | None:
    """メモリ → DB の順にキャッシュを探す。"""
    hit = analysis_cache.memory_get(key)
    if hit is not None:
        logger.info("Analysis cache hit (memory): %s", key)
        return hit

    hit = await store.get_cached_analysis(owner, repo, commit_sha)
    if hit is not None:
        logger.info("Analysis cache hit (db): %s", key)
        # 次回以降はDB読み取りも省けるようメモリにも載せる。
        analysis_cache.memory_put(key, hit)
    return hit


def _ensure_can_read(result: AnalysisResult, *, caller_has_access: bool) -> None:
    """privateリポジトリの解析結果は、いま実際にPATを持っている場合のみ返す。

    ユーザーごとにキャッシュを分けるのではなく都度確認する方式にしているのは、
    トークンを設定画面から削除した後もキャッシュが返り続ける事故を防ぐため。
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
    await store.save_cached_analysis(ref.owner, ref.repo, ref.commit_sha, url=url, result=result)
    return result


# --- 認証（ID / パスワード） -----------------------------------------------


@app.post("/api/v1/auth/register", response_model=AuthResponse)
async def register(request: RegisterRequest) -> AuthResponse:
    if not settings.auth_configured:
        raise HTTPException(status_code=503, detail="Login is not available on this server")

    existing = await store.get_user_by_email(request.email)
    if existing is not None:
        raise HTTPException(status_code=409, detail="An account with this email already exists")

    user = await store.create_user(
        email=request.email,
        hashed_password=hash_password(request.password),
        display_name=request.display_name,
    )
    token = create_access_token(user.id)
    return AuthResponse(access_token=token, uid=str(user.id), email=user.email, name=user.display_name)


@app.post("/api/v1/auth/login", response_model=AuthResponse)
async def login(request: LoginRequest) -> AuthResponse:
    if not settings.auth_configured:
        raise HTTPException(status_code=503, detail="Login is not available on this server")

    user = await store.get_user_by_email(request.email)
    if user is None or not verify_password(request.password, user.hashed_password):
        # メール不存在とパスワード誤りを区別しない（アカウントの存在を推測させないため）。
        raise HTTPException(status_code=401, detail="Invalid email or password")

    token = create_access_token(user.id)
    return AuthResponse(access_token=token, uid=str(user.id), email=user.email, name=user.display_name)


# --- アカウント / GitHubトークン --------------------------------------------


@app.get("/api/v1/me", response_model=MeResponse)
async def me(user: AuthUser = Depends(require_user)) -> MeResponse:
    stored = await store.get_user_dict(user.uid) or {}
    return MeResponse(
        uid=user.uid,
        email=user.email,
        name=user.name,
        picture=user.picture,
        github_login=stored.get("github_login"),
        has_github_token=bool(stored.get("github_token_encrypted")),
    )


@app.put("/api/v1/github/token", response_model=GithubTokenStatusResponse)
async def save_github_token(
    request: SaveGithubTokenRequest,
    user: AuthUser = Depends(require_user),
) -> GithubTokenStatusResponse:
    """設定画面から入力されたPersonal Access Tokenを保存する。

    暗号化してDBに保存する。ログアウトして再ログインしても再入力なしで使えるようにするため。
    """
    try:
        github_login = await verify_user_token(request.token)
    except InvalidTokenError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e

    saved = await store.save_github_user_token(user.uid, request.token, github_login=github_login)
    if not saved:
        # 暗号化鍵未設定などで保存できなかった場合。平文では絶対に保存しない。
        raise HTTPException(
            status_code=503,
            detail="Token storage is not available on this server",
        )

    return GithubTokenStatusResponse(has_github_token=True, github_login=github_login)


@app.delete("/api/v1/github/token", response_model=GithubTokenStatusResponse)
async def delete_github_token(user: AuthUser = Depends(require_user)) -> GithubTokenStatusResponse:
    await store.clear_github_user_token(user.uid)
    return GithubTokenStatusResponse(has_github_token=False, github_login=None)


@app.get("/api/v1/repositories", response_model=RepositoryListResponse)
async def list_repositories(user: AuthUser = Depends(require_user)) -> RepositoryListResponse:
    """保存済みのPATでアクセスできるリポジトリ一覧（プライベート含む）。"""
    token = await store.load_github_user_token(user.uid)
    if token is None:
        raise HTTPException(
            status_code=400,
            detail="No GitHub token is saved. Add one in account settings first.",
        )

    try:
        found = await list_my_repositories(token)
    except InvalidTokenError as e:
        # 保存済みトークンが失効しているケース。設定画面での再入力を促す。
        raise HTTPException(status_code=401, detail=str(e)) from e

    repositories = [
        RepositorySummary(
            full_name=repository["full_name"],
            html_url=repository["html_url"],
            default_branch=repository.get("default_branch", "main"),
            private=bool(repository.get("private")),
            description=repository.get("description"),
            language=repository.get("language"),
        )
        for repository in found
    ]
    repositories.sort(key=lambda r: r.full_name)
    return RepositoryListResponse(repositories=repositories)


# --- 学習履歴 -------------------------------------------------------------


@app.post("/api/v1/progress/answer")
async def record_answer(
    request: AnswerRequest,
    user: AuthUser = Depends(require_user),
) -> dict[str, str]:
    await store.record_answer(user.uid, request.repository_id, request.correct)
    return {"status": "ok"}


@app.get("/api/v1/progress", response_model=ProgressResponse)
async def get_progress(user: AuthUser = Depends(require_user)) -> ProgressResponse:
    raw = await store.get_progress(user.uid)
    return ProgressResponse(
        learning_progress={
            repository_id: {
                "total_answered": entry.get("total_answered", 0),
                "correct_count": entry.get("correct_count", 0),
            }
            for repository_id, entry in raw.items()
        }
    )
