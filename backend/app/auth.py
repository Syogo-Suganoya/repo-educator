"""Firebase Authentication の ID トークン検証。

このアプリでは認証は「任意」である。未ログインのまま公開リポジトリを学習できる体験を
壊さないため、クイズ生成では optional_user を使い、Authorization ヘッダがなければ
黙って None を返す。ログインが前提の機能だけが require_user を使う。
"""

import logging
from dataclasses import dataclass

from fastapi import Depends, HTTPException, Request

from app.config import settings

logger = logging.getLogger(__name__)

_initialized = False


@dataclass(frozen=True)
class AuthUser:
    uid: str
    email: str | None
    name: str | None
    picture: str | None


def _ensure_firebase_app() -> bool:
    """firebase_admin を遅延初期化する。設定が無い場合は False を返す。"""
    global _initialized
    if _initialized:
        return True
    if not settings.firebase_auth_configured:
        return False

    import firebase_admin

    if not firebase_admin._apps:
        project_id = settings.firebase_project_id or settings.gcp_project
        firebase_admin.initialize_app(options={"projectId": project_id})
    _initialized = True
    return True


def _extract_bearer(request: Request) -> str | None:
    header = request.headers.get("Authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        return None
    return token.strip()


def _verify(token: str) -> AuthUser:
    from firebase_admin import auth as firebase_auth

    decoded = firebase_auth.verify_id_token(token)
    return AuthUser(
        uid=decoded["uid"],
        email=decoded.get("email"),
        name=decoded.get("name"),
        picture=decoded.get("picture"),
    )


async def optional_user(request: Request) -> AuthUser | None:
    """認証されていれば AuthUser を、されていなければ None を返す。

    トークンが不正な場合も None ではなく401にする。ログイン済みのつもりの
    ユーザーが黙って未ログイン扱いになると、privateリポジトリが404に見えて
    原因が分からなくなるため。
    """
    token = _extract_bearer(request)
    if token is None:
        return None
    if not _ensure_firebase_app():
        # 認証基盤が未設定の環境では、トークンが来ても検証できない。
        # 公開リポジトリの利用は続けられるよう未ログイン扱いにする。
        logger.warning("Received a bearer token but Firebase Auth is not configured; ignoring it")
        return None

    try:
        return _verify(token)
    except Exception as e:
        # 例外メッセージにトークンが含まれうるので、そのままクライアントに返さない。
        logger.warning("ID token verification failed: %s", type(e).__name__)
        raise HTTPException(status_code=401, detail="Invalid authentication token") from e


async def require_user(user: AuthUser | None = Depends(optional_user)) -> AuthUser:
    if user is None:
        raise HTTPException(status_code=401, detail="Authentication required")
    return user
