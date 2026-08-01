"""Firestore アクセス層。

クライアントからの直接アクセスは Firestore ルールで全面拒否し、
読み書きはすべてこのモジュール（Admin SDK）を通す。

Firestore が未設定のローカル開発では全メソッドが no-op / None を返し、
アプリはキャッシュも履歴もない状態で動き続ける。
"""

import logging
from typing import Any

from app.analysis_cache import AnalysisResult, HeadRef, cache_key, head_key
from app.config import settings
from app.crypto import decrypt, encrypt
from app.schemas import DocEntry, FeatureSection

logger = logging.getLogger(__name__)

USERS_COLLECTION = "users"
REPOSITORIES_COLLECTION = "repositories"
# ブランチ先頭のポインタ。解析結果とは別に、軽い読み取りで済むよう分けている。
HEADS_COLLECTION = "repository_heads"

_db = None


def firestore_available() -> bool:
    return settings.firestore_configured


def _get_db():
    global _db
    if _db is None:
        from google.cloud import firestore

        project = settings.firebase_project_id or settings.gcp_project
        _db = firestore.Client(project=project)
    return _db


# --- users ---------------------------------------------------------------


def get_user(uid: str) -> dict[str, Any] | None:
    if not firestore_available():
        return None
    try:
        snapshot = _get_db().collection(USERS_COLLECTION).document(uid).get()
        return snapshot.to_dict() if snapshot.exists else None
    except Exception as e:
        logger.warning("Firestore get_user failed: %s", type(e).__name__)
        return None


def upsert_user(uid: str, *, email: str | None, name: str | None) -> None:
    if not firestore_available():
        return
    from google.cloud import firestore

    try:
        _get_db().collection(USERS_COLLECTION).document(uid).set(
            {
                "uid": uid,
                "email": email,
                "display_name": name,
                "created_at": firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
    except Exception as e:
        logger.warning("Firestore upsert_user failed: %s", type(e).__name__)


def save_github_user_token(uid: str, token: str) -> None:
    """GitHubユーザートークンをKMSで暗号化して保存する。暗号化できなければ保存しない。"""
    if not firestore_available():
        return
    ciphertext = encrypt(token)
    if ciphertext is None:
        logger.info("Skipping GitHub user token persistence (KMS not configured)")
        return
    try:
        _get_db().collection(USERS_COLLECTION).document(uid).set(
            {"github_user_token_encrypted": ciphertext}, merge=True
        )
    except Exception as e:
        logger.warning("Firestore save_github_user_token failed: %s", type(e).__name__)


def load_github_user_token(uid: str) -> str | None:
    user = get_user(uid)
    if not user:
        return None
    return decrypt(user.get("github_user_token_encrypted"))


def set_installations(uid: str, installation_ids: list[int], github_login: str | None = None) -> None:
    if not firestore_available():
        return
    payload: dict[str, Any] = {"installations": sorted(set(installation_ids))}
    if github_login:
        payload["github_login"] = github_login
    try:
        _get_db().collection(USERS_COLLECTION).document(uid).set(payload, merge=True)
    except Exception as e:
        logger.warning("Firestore set_installations failed: %s", type(e).__name__)


def add_installation(uid: str, installation_id: int) -> None:
    existing = get_installations(uid)
    set_installations(uid, [*existing, installation_id])


def get_installations(uid: str) -> list[int]:
    user = get_user(uid)
    if not user:
        return []
    return [int(i) for i in user.get("installations", [])]


# --- learning progress ---------------------------------------------------


def record_answer(uid: str, repository_id: str, correct: bool) -> None:
    if not firestore_available():
        return
    from google.cloud import firestore

    try:
        doc = _get_db().collection(USERS_COLLECTION).document(uid)
        doc.set(
            {
                "learning_progress": {
                    repository_id: {
                        "total_answered": firestore.Increment(1),
                        "correct_count": firestore.Increment(1 if correct else 0),
                        "last_accessed": firestore.SERVER_TIMESTAMP,
                    }
                }
            },
            merge=True,
        )
    except Exception as e:
        logger.warning("Firestore record_answer failed: %s", type(e).__name__)


def get_progress(uid: str) -> dict[str, Any]:
    user = get_user(uid)
    if not user:
        return {}
    return user.get("learning_progress", {}) or {}


# --- quiz cache ----------------------------------------------------------


def get_head(owner: str, repo: str, branch: str) -> HeadRef | None:
    """あるブランチについて最後に確認したコミットSHAとpush時刻を返す。

    これがあると、pushがない限りコミットSHAの問い合わせを省ける。
    """
    if not firestore_available():
        return None
    try:
        doc_id = head_key(owner, repo, branch)
        snapshot = _get_db().collection(HEADS_COLLECTION).document(doc_id).get()
        if not snapshot.exists:
            return None
        data = snapshot.to_dict() or {}
        if not data.get("commit_sha"):
            return None
        return HeadRef(commit_sha=data["commit_sha"], pushed_at=data.get("pushed_at"))
    except Exception as e:
        logger.warning("Firestore get_head failed: %s", type(e).__name__)
        return None


def save_head(owner: str, repo: str, branch: str, head: HeadRef) -> None:
    if not firestore_available():
        return
    from google.cloud import firestore

    try:
        doc_id = head_key(owner, repo, branch)
        _get_db().collection(HEADS_COLLECTION).document(doc_id).set(
            {
                "owner": owner,
                "repo": repo,
                "branch": branch,
                "commit_sha": head.commit_sha,
                "pushed_at": head.pushed_at,
                "checked_at": firestore.SERVER_TIMESTAMP,
            }
        )
    except Exception as e:
        logger.warning("Firestore save_head failed: %s", type(e).__name__)


def get_cached_analysis(owner: str, repo: str, commit_sha: str) -> AnalysisResult | None:
    """キャッシュ済みの解析結果を返す。キャッシュがなければ None。

    **アクセス権の判定はここでは行わない。** 呼び出し側（main.py）が
    `AnalysisResult.private` を見て都度確認する。判定を1箇所に集約するため。
    """
    if not firestore_available():
        return None
    try:
        doc_id = cache_key(owner, repo, commit_sha)
        snapshot = _get_db().collection(REPOSITORIES_COLLECTION).document(doc_id).get()
        if not snapshot.exists:
            return None
        data = snapshot.to_dict() or {}

        # ドキュメント機能の追加前に作られたキャッシュには docs がない。
        docs = [DocEntry(**doc) for doc in data.get("docs", [])]

        # Firestoreのマップキーは文字列なので、出題数はintに戻す。
        sections_by_count: dict[int, list[FeatureSection]] = {}
        for count, sections in (data.get("sections_by_count") or {}).items():
            try:
                sections_by_count[int(count)] = [FeatureSection(**s) for s in sections]
            except (TypeError, ValueError):
                continue

        return AnalysisResult(
            private=data.get("visibility") == "private",
            docs=docs,
            sections_by_count=sections_by_count,
        )
    except Exception as e:
        logger.warning("Firestore get_cached_analysis failed: %s", type(e).__name__)
        return None


def save_cached_analysis(
    owner: str,
    repo: str,
    commit_sha: str,
    *,
    url: str,
    result: AnalysisResult,
) -> None:
    """解析結果を保存する。

    出題数ごとのクイズは既存のものを消さずに足していく（merge）。
    5問で生成済みのリポジトリを別のユーザーが10問で開いても、
    5問分のキャッシュが失われないようにするため。
    """
    if not firestore_available():
        return
    from google.cloud import firestore

    try:
        doc_id = cache_key(owner, repo, commit_sha)
        _get_db().collection(REPOSITORIES_COLLECTION).document(doc_id).set(
            {
                "repository_id": doc_id,
                "url": url,
                "commit_sha": commit_sha,
                "visibility": "private" if result.private else "public",
                "analyzed_at": firestore.SERVER_TIMESTAMP,
                "docs": [d.model_dump() for d in result.docs],
                "sections_by_count": {
                    str(count): [s.model_dump() for s in sections]
                    for count, sections in result.sections_by_count.items()
                },
            },
            merge=True,
        )
    except Exception as e:
        logger.warning("Firestore save_cached_analysis failed: %s", type(e).__name__)
