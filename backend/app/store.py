"""PostgreSQL アクセス層。

クライアント（フロントエンド）からの直接アクセスはできない構成にしてある
（DB接続情報を持つのはバックエンドのみ）。読み書きはすべてこのモジュールを通す。

DATABASE_URL が未設定のローカル開発では全メソッドが no-op / None を返し、
アプリはキャッシュも履歴もない状態で動き続ける。
"""

import logging
import uuid
from typing import Any

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from app.analysis_cache import AnalysisResult, HeadRef
from app.config import settings
from app.crypto import decrypt, encrypt
from app.db import AnalysisCache, LearningProgress, RepositoryHead, User, get_session_factory
from app.schemas import DocEntry, FeatureSection

logger = logging.getLogger(__name__)


def db_available() -> bool:
    return settings.db_configured


# --- users -------------------------------------------------------------------


async def get_user_by_id(user_id: uuid.UUID) -> User | None:
    if not db_available():
        return None
    try:
        async with get_session_factory()() as session:
            return await session.get(User, user_id)
    except Exception as e:
        logger.warning("DB get_user_by_id failed: %s", type(e).__name__)
        return None


async def get_user_by_email(email: str) -> User | None:
    if not db_available():
        return None
    try:
        async with get_session_factory()() as session:
            result = await session.execute(select(User).where(User.email == email))
            return result.scalar_one_or_none()
    except Exception as e:
        logger.warning("DB get_user_by_email failed: %s", type(e).__name__)
        return None


async def create_user(*, email: str, hashed_password: str, display_name: str | None) -> User:
    """新規ユーザーを作成する。呼び出し側でメールの重複確認を済ませておくこと。"""
    async with get_session_factory()() as session:
        user = User(email=email, hashed_password=hashed_password, display_name=display_name)
        session.add(user)
        await session.commit()
        await session.refresh(user)
        return user


async def get_user_dict(uid: str) -> dict[str, Any] | None:
    """他の関数が Firestore 時代と同じ辞書形状で扱えるようにする互換ヘルパー。"""
    user = await get_user_by_id(uuid.UUID(uid))
    if user is None:
        return None
    return {
        "uid": str(user.id),
        "email": user.email,
        "display_name": user.display_name,
        "github_login": user.github_login,
        "github_token_encrypted": user.github_token_encrypted,
    }


async def save_github_user_token(uid: str, token: str, *, github_login: str | None = None) -> bool:
    """ユーザーが自分で入力したGitHub PATを暗号化して保存する。

    ログアウト後も残るよう、環境変数やセッションではなくDBに保存する。
    暗号化できなければ保存しない（平文保存はしない）。戻り値は保存できたかどうか。
    """
    if not db_available():
        return False
    ciphertext = encrypt(token)
    if ciphertext is None:
        logger.info("Skipping GitHub token persistence (encryption key not configured)")
        return False
    try:
        async with get_session_factory()() as session:
            user = await session.get(User, uuid.UUID(uid))
            if user is None:
                return False
            user.github_token_encrypted = ciphertext
            if github_login:
                user.github_login = github_login
            await session.commit()
            return True
    except Exception as e:
        logger.warning("DB save_github_user_token failed: %s", type(e).__name__)
        return False


async def clear_github_user_token(uid: str) -> None:
    if not db_available():
        return
    try:
        async with get_session_factory()() as session:
            user = await session.get(User, uuid.UUID(uid))
            if user is None:
                return
            user.github_token_encrypted = None
            user.github_login = None
            await session.commit()
    except Exception as e:
        logger.warning("DB clear_github_user_token failed: %s", type(e).__name__)


async def load_github_user_token(uid: str) -> str | None:
    user = await get_user_by_id(uuid.UUID(uid))
    if user is None:
        return None
    return decrypt(user.github_token_encrypted)


# --- learning progress ---------------------------------------------------


async def record_answer(uid: str, repository_id: str, correct: bool) -> None:
    if not db_available():
        return
    try:
        async with get_session_factory()() as session:
            result = await session.execute(
                select(LearningProgress).where(
                    LearningProgress.user_id == uuid.UUID(uid),
                    LearningProgress.repository_id == repository_id,
                )
            )
            progress = result.scalar_one_or_none()
            if progress is None:
                progress = LearningProgress(
                    user_id=uuid.UUID(uid),
                    repository_id=repository_id,
                    total_answered=0,
                    correct_count=0,
                )
                session.add(progress)
            progress.total_answered += 1
            if correct:
                progress.correct_count += 1
            await session.commit()
    except Exception as e:
        logger.warning("DB record_answer failed: %s", type(e).__name__)


async def get_progress(uid: str) -> dict[str, Any]:
    if not db_available():
        return {}
    try:
        async with get_session_factory()() as session:
            result = await session.execute(
                select(LearningProgress).where(LearningProgress.user_id == uuid.UUID(uid))
            )
            return {
                row.repository_id: {
                    "total_answered": row.total_answered,
                    "correct_count": row.correct_count,
                }
                for row in result.scalars()
            }
    except Exception as e:
        logger.warning("DB get_progress failed: %s", type(e).__name__)
        return {}


# --- リポジトリ更新確認（ブランチ先頭のポインタ） --------------------------


async def get_head(owner: str, repo: str, branch: str) -> HeadRef | None:
    """あるブランチについて最後に確認したコミットSHAとpush時刻を返す。

    これがあると、pushがない限りコミットSHAの問い合わせを省ける。
    """
    if not db_available():
        return None
    try:
        async with get_session_factory()() as session:
            result = await session.execute(
                select(RepositoryHead).where(
                    RepositoryHead.owner == owner,
                    RepositoryHead.repo == repo,
                    RepositoryHead.branch == branch,
                )
            )
            row = result.scalar_one_or_none()
            if row is None:
                return None
            return HeadRef(commit_sha=row.commit_sha, pushed_at=row.pushed_at)
    except Exception as e:
        logger.warning("DB get_head failed: %s", type(e).__name__)
        return None


async def save_head(owner: str, repo: str, branch: str, head: HeadRef) -> None:
    if not db_available():
        return
    try:
        async with get_session_factory()() as session:
            stmt = (
                pg_insert(RepositoryHead)
                .values(
                    owner=owner,
                    repo=repo,
                    branch=branch,
                    commit_sha=head.commit_sha,
                    pushed_at=head.pushed_at,
                )
                .on_conflict_do_update(
                    index_elements=["owner", "repo", "branch"],
                    set_={"commit_sha": head.commit_sha, "pushed_at": head.pushed_at},
                )
            )
            await session.execute(stmt)
            await session.commit()
    except Exception as e:
        logger.warning("DB save_head failed: %s", type(e).__name__)


# --- 解析結果キャッシュ ----------------------------------------------------


async def get_cached_analysis(owner: str, repo: str, commit_sha: str) -> AnalysisResult | None:
    """キャッシュ済みの解析結果を返す。キャッシュがなければ None。

    **アクセス権の判定はここでは行わない。** 呼び出し側（main.py）が
    `AnalysisResult.private` を見て都度確認する。判定を1箇所に集約するため。
    """
    if not db_available():
        return None
    try:
        async with get_session_factory()() as session:
            result = await session.execute(
                select(AnalysisCache).where(
                    AnalysisCache.owner == owner,
                    AnalysisCache.repo == repo,
                    AnalysisCache.commit_sha == commit_sha,
                )
            )
            row = result.scalar_one_or_none()
            if row is None:
                return None

            docs = [DocEntry(**doc) for doc in (row.docs or [])]

            # JSONのキーは文字列になるので、出題数はintに戻す。
            sections_by_count: dict[int, list[FeatureSection]] = {}
            for count, sections in (row.sections_by_count or {}).items():
                try:
                    sections_by_count[int(count)] = [FeatureSection(**s) for s in sections]
                except (TypeError, ValueError):
                    continue

            return AnalysisResult(
                private=row.visibility == "private",
                docs=docs,
                sections_by_count=sections_by_count,
            )
    except Exception as e:
        logger.warning("DB get_cached_analysis failed: %s", type(e).__name__)
        return None


async def save_cached_analysis(
    owner: str,
    repo: str,
    commit_sha: str,
    *,
    url: str,
    result: AnalysisResult,
) -> None:
    """解析結果を保存する。

    出題数ごとのクイズは既存のものを消さずに足していく。
    5問で生成済みのリポジトリを別のユーザーが10問で開いても、
    5問分のキャッシュが失われないようにするため。
    """
    if not db_available():
        return
    try:
        async with get_session_factory()() as session:
            query = await session.execute(
                select(AnalysisCache).where(
                    AnalysisCache.owner == owner,
                    AnalysisCache.repo == repo,
                    AnalysisCache.commit_sha == commit_sha,
                )
            )
            row = query.scalar_one_or_none()

            sections_json = {
                str(count): [s.model_dump() for s in sections]
                for count, sections in result.sections_by_count.items()
            }
            docs_json = [d.model_dump() for d in result.docs]

            if row is None:
                row = AnalysisCache(
                    owner=owner,
                    repo=repo,
                    commit_sha=commit_sha,
                    url=url,
                    visibility="private" if result.private else "public",
                    docs=docs_json,
                    sections_by_count=sections_json,
                )
                session.add(row)
            else:
                row.url = url
                row.visibility = "private" if result.private else "public"
                row.docs = docs_json
                merged = dict(row.sections_by_count or {})
                merged.update(sections_json)
                row.sections_by_count = merged

            await session.commit()
    except Exception as e:
        logger.warning("DB save_cached_analysis failed: %s", type(e).__name__)
