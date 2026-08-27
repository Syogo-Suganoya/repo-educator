import asyncio
import logging
import time

from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from app import analysis_cache, qa, store
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
    RepositoryMeta,
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
from app.gemini import GeminiError, GeminiQuotaExceededError
from app.quiz_generator import generate_quizzes
from app.sample_docs import get_sample_docs
from app.sample_quizzes import get_sample_sections
from app.schemas import (
    AnswerRequest,
    AuthResponse,
    DocAnswerResponse,
    DocQuestionRequest,
    FeatureSection,
    GenerationHistoryItem,
    GenerationHistoryResponse,
    GithubTokenListResponse,
    GithubTokenSummary,
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

    # サンプルリポジトリは実コードを元に用意したキュレーション済みデータを即座に返す。
    # 「すぐ試せる」ことが目的なので、Geminiの設定有無に関わらずここで打ち切り、
    # GitHubの取得もGeminiの生成も走らせない。
    # 出題リクエストがある場合だけは、キュレーション済みデータでは応えられないので生成に回す。
    sample_sections = None if request.focus else get_sample_sections(owner, repo)
    if sample_sections is not None:
        repository_id = f"{owner}_{repo}_{request.branch}"
        if not request.from_sample:
            await _remember_generation(
                user,
                request=request,
                repository_id=repository_id,
                sections=sample_sections,
            )
        return QuizGenerateResponse(
            repository_id=repository_id,
            url=request.repository_url,
            sections=sample_sections,
            docs=get_sample_docs(owner, repo) or [],
        )

    # ログイン済みなら、本人が登録したPATのうちこのリポジトリを読めるものを使う
    # （サーバ共有の環境変数とは別物）。
    try:
        user_token, repo_meta = await _resolve_user_token(user, owner, repo, request.branch)
    except RateLimitedError as e:
        raise HTTPException(status_code=429, detail=_rate_limit_message(e)) from e

    # まずリポジトリの最終push時刻だけを見る（GitHub API 1回）。
    # 前回と変化がなければ、コミットSHAの問い合わせもソースの取得も省ける。
    try:
        ref = await _resolve_ref(owner, repo, request.branch, user_token, repo_meta)
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
        # 出題リクエストがあるときは、観点が違うので既存の結果を使い回さない。
        sections = None if request.focus else cached.sections_for(request.num_questions)
        if sections is not None:
            await _remember_generation(
                user, request=request, repository_id=repository_id, sections=sections
            )
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
            focus=request.focus,
        )

    # リクエスト文まで含めて初めて「同じ処理」と言えるので、合流のキーにも含める。
    inflight_key = f"{key}:{request.num_questions}:{request.focus or ''}"
    try:
        result = await analysis_cache.run_once(inflight_key, build)
    except RepositoryNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    except RepositoryAccessDeniedError as e:
        raise HTTPException(status_code=403, detail=str(e)) from e
    except RateLimitedError as e:
        raise HTTPException(status_code=429, detail=_rate_limit_message(e)) from e
    except GeminiQuotaExceededError as e:
        # 待っても短時間では回復しないので、混雑（503）とは案内を分ける。
        logger.warning("Gemini quota exceeded: %s", e)
        raise HTTPException(
            status_code=429,
            detail="AIの利用上限に達しました。無料枠は1日あたりの回数制限があるため、"
            "枠が回復するまでお待ちいただくか、APIキーのプランをご確認ください。",
        ) from e
    except GeminiError as e:
        # 生成の失敗はサーバのバグではなく、AI側の一時的な事情であることが多い。
        # 500のまま返すと利用者には原因も再試行の可否も分からないため、503にする。
        logger.warning("Gemini generation failed: %s", e)
        raise HTTPException(
            status_code=503,
            detail="AIによる生成に失敗しました。時間をおいて、もう一度お試しください。",
        ) from e

    # 生成を待っている間に権限が変わっている可能性もあるので、返す直前にも確認する。
    _ensure_can_read(result, caller_has_access=caller_has_access)

    sections = result.sections_for(request.num_questions) or []
    await _remember_generation(
        user, request=request, repository_id=repository_id, sections=sections
    )
    return QuizGenerateResponse(
        repository_id=repository_id,
        url=request.repository_url,
        sections=sections,
        docs=result.docs,
        cached=False,
    )


def _count_quizzes(sections: list[FeatureSection]) -> int:
    return sum(len(section.quizzes) for section in sections)


async def _remember_generation(
    user: AuthUser | None,
    *,
    request: QuizGenerateRequest,
    repository_id: str,
    sections: list[FeatureSection],
) -> None:
    """生成したクイズを履歴に残す（ログイン時のみ）。

    未ログインのときはブラウザ側（localStorage）に保存する。サーバに匿名の
    履歴を持たせると、誰のものか特定できないデータが溜まり続けるため。
    """
    if user is None:
        return
    await store.record_generation(
        user.uid,
        repository_url=request.repository_url,
        branch=request.branch,
        repository_id=repository_id,
        section_count=len(sections),
        quiz_count=_count_quizzes(sections),
    )


@app.post("/api/v1/docs/ask", response_model=DocAnswerResponse)
async def ask_about_repository(
    request: DocQuestionRequest,
    user: AuthUser | None = Depends(optional_user),
) -> DocAnswerResponse:
    """リポジトリについての質問に、実際のソースコードを根拠に答える。

    クイズ生成と違い、質問は毎回異なるためキャッシュしない。
    アクセス権の判定はクイズ側と同じ厳しさを保つ（回答にコードが引用されるため）。
    """
    try:
        owner, repo = parse_repository_url(request.repository_url)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e

    try:
        user_token, repo_meta = await _resolve_user_token(user, owner, repo, request.branch)
        ref = await _resolve_ref(owner, repo, request.branch, user_token, repo_meta)
        if ref.private and user_token is None:
            raise HTTPException(
                status_code=403,
                detail="You no longer have access to this repository",
            )
        files = await fetch_repository_files(ref, request.branch, user_token)
        answer, file_paths = await qa.answer_question(files, request.question)
    except RepositoryNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    except RepositoryAccessDeniedError as e:
        raise HTTPException(status_code=403, detail=str(e)) from e
    except RateLimitedError as e:
        raise HTTPException(status_code=429, detail=_rate_limit_message(e)) from e
    except GeminiQuotaExceededError as e:
        logger.warning("Gemini quota exceeded: %s", e)
        raise HTTPException(
            status_code=429,
            detail="AIの利用上限に達しました。無料枠は1日あたりの回数制限があるため、"
            "枠が回復するまでお待ちいただくか、APIキーのプランをご確認ください。",
        ) from e
    except GeminiError as e:
        logger.warning("Gemini answer failed: %s", e)
        raise HTTPException(
            status_code=503,
            detail="AIによる回答に失敗しました。時間をおいて、もう一度お試しください。",
        ) from e

    return DocAnswerResponse(answer=answer, file_paths=file_paths)


def _rate_limit_message(error: RateLimitedError) -> str:
    """レートリミットの解除時刻を分単位で伝える。

    未認証は60req/hしかない。ログインして自分のPATを設定画面から登録すると
    5,000req/hになるため、フロント側はこの案内と合わせてトークン入力欄へ誘導できる。
    """
    if error.reset_epoch:
        minutes = max(1, (error.reset_epoch - int(time.time()) + 59) // 60)
        return f"GitHub API rate limit exceeded. Retry in about {minutes} minute(s)."
    return "GitHub API rate limit exceeded. Please retry later."


async def _resolve_user_token(
    user: AuthUser | None, owner: str, repo: str, branch: str
) -> tuple[str | None, RepositoryMeta | None]:
    """このリポジトリを読めるトークンを1本選び、取得済みのメタ情報と一緒に返す。

    どのトークンがどのリポジトリに効くかは事前に分からないため、総当たりで探す。
    ただし毎回全部試すのは無駄なので、成功した組み合わせを記録し、次回はそれを先に試す。

    記録済みの組み合わせが後日失敗することがある（利用者がGitHub側で対象リポジトリを
    変更した場合）。そのときは記録を捨て、残りのトークンで探し直す。

    戻り値の RepositoryMeta は探索の過程で取得済みのものを使い回す。
    呼び出し側で取り直すと、同じ問い合わせでレートリミットを二重に消費してしまう。
    """
    if user is None:
        return None, None

    tokens = await store.list_github_tokens(user.uid)
    if not tokens:
        return None, None

    bound_id = await store.get_repo_binding(user.uid, owner, repo)
    # 記録済みのものを先頭に持ってくる。当たれば1回の問い合わせで済む。
    ordered = sorted(tokens, key=lambda t: t["id"] != bound_id)

    for candidate in ordered:
        try:
            meta = await fetch_repository_meta(owner, repo, branch, candidate["token"])
        except (RepositoryNotFoundError, RepositoryAccessDeniedError):
            # このトークンでは読めないだけ。次を試す。
            continue
        except InvalidTokenError:
            # 失効したトークン。他のトークンでは読めるかもしれないので続ける。
            logger.info("Skipping an invalid GitHub token while resolving %s/%s", owner, repo)
            continue

        if candidate["id"] != bound_id:
            await store.save_repo_binding(user.uid, owner, repo, candidate["id"])
        return candidate["token"], meta

    # どのトークンでも読めなかった。古い記録が残っていれば捨てる。
    if bound_id is not None:
        await store.delete_repo_binding(user.uid, owner, repo)
    return None, None


async def _resolve_ref(
    owner: str,
    repo: str,
    branch: str,
    token: str | None,
    meta: RepositoryMeta | None = None,
) -> RepositoryRef:
    """対象コミットを決める。GitHubへの問い合わせを最小限に抑える。

      1. リポジトリ情報を取得（1回）… private と pushed_at
      2. 前回見た pushed_at と同じなら、記録済みのコミットSHAをそのまま使う
      3. 違えば（または記録がなければ）コミットSHAを問い合わせる（1回）

    pushed_at はリポジトリ全体の値で、別ブランチへのpushでも進む。
    そのため「進んでいたら再生成」ではなく「進んでいたらSHAを確認する」に留める。
    SHAが同じなら解析結果はそのまま再利用される。
    """
    # トークンの探索時に取得済みなら、同じ問い合わせを繰り返さない。
    meta = meta or await fetch_repository_meta(owner, repo, branch, token)
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
    focus: str | None = None,
) -> AnalysisResult:
    """不足している分だけを生成し、キャッシュに書き戻す。

    ドキュメントは出題数に依存しないため、既にキャッシュがあれば再生成しない。
    「同じリポジトリを別の出題数で開いただけ」でドキュメントまで作り直すのを避ける。

    出題リクエスト（focus）付きの結果はその人の指示に固有なので、
    共有キャッシュには保存しない。保存すると、指示していない別の利用者が
    その観点に偏ったクイズを受け取ってしまう。
    """
    files = await fetch_repository_files(ref, branch, token)

    # 出題リクエストは出題内容だけを変えるもので、ドキュメントには影響しない。
    needs_docs = not focus and (known is None or not known.docs)
    if needs_docs:
        sections, docs = await asyncio.gather(
            generate_quizzes(files, num_questions, focus_language, focus),
            generate_docs(files, focus_language),
        )
    else:
        sections = await generate_quizzes(files, num_questions, focus_language, focus)
        docs = known.docs if known else []

    result = AnalysisResult(
        private=ref.private,
        docs=docs,
        sections_by_count={
            **(known.sections_by_count if known else {}),
            num_questions: sections,
        },
    )

    if focus:
        return result

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
    tokens = await store.list_github_tokens(user.uid)
    return MeResponse(
        uid=user.uid,
        email=user.email,
        name=user.name,
        picture=user.picture,
        github_login=tokens[0]["github_login"] if tokens else None,
        has_github_token=bool(tokens),
        github_token_count=len(tokens),
    )


@app.get("/api/v1/github/tokens", response_model=GithubTokenListResponse)
async def list_github_tokens(user: AuthUser = Depends(require_user)) -> GithubTokenListResponse:
    """登録済みトークンの一覧。トークンの値そのものは絶対に返さない。"""
    tokens = await store.list_github_tokens(user.uid)
    return GithubTokenListResponse(
        tokens=[
            GithubTokenSummary(
                id=t["id"],
                label=t["label"],
                github_login=t["github_login"],
                created_at=t["created_at"],
            )
            for t in tokens
        ]
    )


@app.post("/api/v1/github/tokens", response_model=GithubTokenListResponse)
async def add_github_token(
    request: SaveGithubTokenRequest,
    user: AuthUser = Depends(require_user),
) -> GithubTokenListResponse:
    """設定画面から入力されたPersonal Access Tokenを追加する。

    暗号化してDBに保存する。ログアウトして再ログインしても再入力なしで使えるようにするため。
    複数登録できる（Fine-grained PAT は対象リポジトリを絞るため、1本では足りないことがある）。
    """
    try:
        github_login = await verify_user_token(request.token)
    except InvalidTokenError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e

    label = (request.label or "").strip() or None
    saved = await store.add_github_token(
        user.uid,
        request.token,
        github_login=github_login,
        label=label,
    )
    if not saved:
        # 暗号化鍵未設定などで保存できなかった場合。平文では絶対に保存しない。
        raise HTTPException(
            status_code=503,
            detail="Token storage is not available on this server",
        )

    return await list_github_tokens(user)


@app.delete("/api/v1/github/tokens/{token_id}", response_model=GithubTokenListResponse)
async def delete_github_token(
    token_id: int,
    user: AuthUser = Depends(require_user),
) -> GithubTokenListResponse:
    await store.delete_github_token(user.uid, token_id)
    return await list_github_tokens(user)


@app.get("/api/v1/repositories", response_model=RepositoryListResponse)
async def list_repositories(user: AuthUser = Depends(require_user)) -> RepositoryListResponse:
    """保存済みのPATで読めるプライベートリポジトリの一覧。

    公開リポジトリはURLを貼るだけで解析できるので、この一覧には載せない。
    ここは「PATを登録しないと辿り着けないもの」だけを見せる導線にする。
    """
    tokens = await store.list_github_tokens(user.uid)
    if not tokens:
        raise HTTPException(
            status_code=400,
            detail="No GitHub token is saved. Add one in account settings first.",
        )

    # トークンごとに見えるリポジトリが違うので、全部を集めて重複を除く。
    found: dict[str, dict] = {}
    invalid_only = True
    for entry in tokens:
        try:
            for repository in await list_my_repositories(entry["token"]):
                found.setdefault(repository["full_name"], repository)
            invalid_only = False
        except InvalidTokenError:
            # 1本が失効していても、他のトークンで見える分は返す。
            logger.info("Skipping an invalid GitHub token while listing repositories")

    if invalid_only:
        raise HTTPException(
            status_code=401,
            detail="The provided GitHub token is invalid or has expired",
        )

    repositories = [
        RepositorySummary(
            full_name=repository["full_name"],
            html_url=repository["html_url"],
            default_branch=repository.get("default_branch", "main"),
            private=bool(repository.get("private")),
            description=repository.get("description"),
            language=repository.get("language"),
        )
        for repository in found.values()
        if repository.get("private")
    ]
    repositories.sort(key=lambda r: r.full_name)
    return RepositoryListResponse(repositories=repositories)


@app.get("/api/v1/history", response_model=GenerationHistoryResponse)
async def list_history(user: AuthUser = Depends(require_user)) -> GenerationHistoryResponse:
    """このユーザーが生成したクイズの履歴（新しい順）。"""
    entries = await store.list_generations(user.uid)
    return GenerationHistoryResponse(
        history=[GenerationHistoryItem(**entry) for entry in entries]
    )


@app.delete("/api/v1/history")
async def delete_history(
    repository_url: str,
    branch: str = "main",
    user: AuthUser = Depends(require_user),
) -> dict[str, bool]:
    await store.delete_generation(user.uid, repository_url=repository_url, branch=branch)
    return {"ok": True}


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
