"""自前のID/パスワード認証（JWT）。

このアプリでは認証は「任意」である。未ログインのまま公開リポジトリを学習できる体験を
壊さないため、クイズ生成では optional_user を使い、Authorization ヘッダがなければ
黙って None を返す。ログインが前提の機能だけが require_user を使う。

以前は Firebase Authentication（GitHub SSO）を使っていたが、通常のメールアドレス+
パスワード認証に切り替えた。本人確認の方式が変わるだけで、GitHubリポジトリへの
アクセスは元々これとは別（ユーザーが設定画面で入力するPersonal Access Token）だった
ため、そちら側への影響はない。
"""

import logging
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import bcrypt
import jwt
from fastapi import Depends, HTTPException, Request

from app.config import settings

logger = logging.getLogger(__name__)

JWT_ALGORITHM = "HS256"


@dataclass(frozen=True)
class AuthUser:
    uid: str
    email: str | None
    name: str | None
    picture: str | None = None


# --- パスワード ------------------------------------------------------------


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, hashed: str) -> bool:
    try:
        return bcrypt.checkpw(password.encode("utf-8"), hashed.encode("utf-8"))
    except ValueError:
        # 壊れたハッシュ値など。認証失敗として扱う。
        return False


# --- JWT --------------------------------------------------------------------


def create_access_token(user_id: uuid.UUID) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user_id),
        "iat": now,
        "exp": now + timedelta(days=settings.jwt_expires_days),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=JWT_ALGORITHM)


def decode_access_token(token: str) -> uuid.UUID | None:
    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=[JWT_ALGORITHM])
        return uuid.UUID(payload["sub"])
    except (jwt.InvalidTokenError, KeyError, ValueError):
        return None


# --- FastAPI 依存性 -----------------------------------------------------------


def _extract_bearer(request: Request) -> str | None:
    header = request.headers.get("Authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        return None
    return token.strip()


async def optional_user(request: Request) -> AuthUser | None:
    """認証されていれば AuthUser を、されていなければ None を返す。

    トークンが不正な場合も None ではなく401にする。ログイン済みのつもりの
    ユーザーが黙って未ログイン扱いになると、privateリポジトリが404に見えて
    原因が分からなくなるため。
    """
    token = _extract_bearer(request)
    if token is None:
        return None
    if not settings.auth_configured:
        # 認証基盤が未設定の環境では、トークンが来ても検証できない。
        # 公開リポジトリの利用は続けられるよう未ログイン扱いにする。
        logger.warning("Received a bearer token but auth is not configured; ignoring it")
        return None

    user_id = decode_access_token(token)
    if user_id is None:
        raise HTTPException(status_code=401, detail="Invalid authentication token")

    from app import store

    user = await store.get_user_by_id(user_id)
    if user is None:
        raise HTTPException(status_code=401, detail="Invalid authentication token")

    return AuthUser(uid=str(user.id), email=user.email, name=user.display_name)


async def require_user(user: AuthUser | None = Depends(optional_user)) -> AuthUser:
    if user is None:
        raise HTTPException(status_code=401, detail="Authentication required")
    return user
