"""GitHub App を使ったプライベートリポジトリへのアクセス。

役割分担:
  - Firebase Auth (GitHubプロバイダ) ... 本人確認。誰なのかを決める
  - GitHub App のインストール         ... リポジトリへのアクセス権

リポジトリ本体の取得に使う installation access token は1時間で失効する短命トークンで、
App秘密鍵から都度発行する。永続化はしない（プロセス内メモリにのみ期限までキャッシュ）。
"""

import base64
import hashlib
import hmac
import json
import logging
import secrets
import time
from typing import Any

import httpx

from app.config import settings

logger = logging.getLogger(__name__)

GITHUB_API = "https://api.github.com"

# 期限ぎりぎりのトークンで長い処理に入らないよう、5分前には再発行する。
_TOKEN_REFRESH_MARGIN_SECONDS = 300
_STATE_TTL_SECONDS = 600

_installation_tokens: dict[int, tuple[str, float]] = {}
_state_secret: str | None = None


class GitHubAppNotConfiguredError(Exception):
    """GitHub App の設定がないため、プライベートリポジトリを扱えない。"""


def app_configured() -> bool:
    return settings.github_app_configured


# --- App JWT / installation token ----------------------------------------


def _build_app_jwt() -> str:
    if not app_configured():
        raise GitHubAppNotConfiguredError("GITHUB_APP_ID / GITHUB_APP_PRIVATE_KEY are not set")

    import jwt

    now = int(time.time())
    payload = {
        # GitHubとの時刻ずれで即時失効しないよう60秒巻き戻す（GitHub公式の推奨）
        "iat": now - 60,
        "exp": now + 540,
        "iss": settings.github_app_id,
    }
    private_key = settings.github_app_private_key.replace("\\n", "\n")
    return jwt.encode(payload, private_key, algorithm="RS256")


async def get_installation_token(installation_id: int) -> str:
    cached = _installation_tokens.get(installation_id)
    if cached and cached[1] - _TOKEN_REFRESH_MARGIN_SECONDS > time.time():
        return cached[0]

    app_jwt = _build_app_jwt()
    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.post(
            f"{GITHUB_API}/app/installations/{installation_id}/access_tokens",
            headers={
                "Authorization": f"Bearer {app_jwt}",
                "Accept": "application/vnd.github+json",
            },
        )
    if response.status_code != 201:
        # レスポンス本文にトークンや内部情報が混ざりうるので、そのままは伝播させない。
        logger.warning(
            "Failed to mint installation token for %s (status=%s)",
            installation_id,
            response.status_code,
        )
        raise GitHubAppNotConfiguredError("Failed to obtain installation access token")

    payload = response.json()
    token = payload["token"]
    expires_at = time.mktime(time.strptime(payload["expires_at"], "%Y-%m-%dT%H:%M:%SZ"))
    _installation_tokens[installation_id] = (token, expires_at)
    return token


# --- ユーザーのインストール一覧 --------------------------------------------


async def list_user_installations(github_user_token: str) -> list[dict[str, Any]]:
    """このユーザーがアクセスできる、当App のインストール一覧を返す。"""
    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.get(
            f"{GITHUB_API}/user/installations",
            headers={
                "Authorization": f"Bearer {github_user_token}",
                "Accept": "application/vnd.github+json",
            },
        )
    if response.status_code != 200:
        logger.warning("GET /user/installations failed (status=%s)", response.status_code)
        return []
    return response.json().get("installations", [])


async def list_installation_repositories(installation_id: int) -> list[dict[str, Any]]:
    """インストールで許可されたリポジトリ一覧（リポジトリ選択UI用）。"""
    token = await get_installation_token(installation_id)
    repositories: list[dict[str, Any]] = []
    async with httpx.AsyncClient(timeout=15.0) as client:
        page = 1
        while True:
            response = await client.get(
                f"{GITHUB_API}/installation/repositories",
                headers={
                    "Authorization": f"Bearer {token}",
                    "Accept": "application/vnd.github+json",
                },
                params={"per_page": 100, "page": page},
            )
            if response.status_code != 200:
                break
            chunk = response.json().get("repositories", [])
            repositories.extend(chunk)
            if len(chunk) < 100:
                break
            page += 1
    return repositories


async def find_installation_token_for_repo(
    installation_ids: list[int], owner: str, repo: str
) -> str | None:
    """指定リポジトリを含むインストールを探し、そのトークンを返す。"""
    target = f"{owner}/{repo}".lower()
    for installation_id in installation_ids:
        try:
            repositories = await list_installation_repositories(installation_id)
        except GitHubAppNotConfiguredError:
            return None
        for repository in repositories:
            if repository.get("full_name", "").lower() == target:
                return await get_installation_token(installation_id)
    return None


# --- インストールURL と state 署名 ------------------------------------------


def _get_state_secret() -> str:
    """state署名鍵。未設定ならプロセス起動ごとのランダム値を使う。

    複数インスタンスで動かす場合は STATE_SECRET を明示的に設定すること
    （インスタンスをまたぐとstate検証に失敗するため）。
    """
    global _state_secret
    if settings.state_secret:
        return settings.state_secret
    if _state_secret is None:
        _state_secret = secrets.token_urlsafe(32)
        logger.warning("STATE_SECRET is not set; using a per-process random secret")
    return _state_secret


def issue_state(uid: str) -> str:
    payload = json.dumps({"uid": uid, "exp": int(time.time()) + _STATE_TTL_SECONDS})
    body = base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")
    signature = hmac.new(_get_state_secret().encode(), body.encode(), hashlib.sha256).hexdigest()
    return f"{body}.{signature}"


def verify_state(state: str) -> str | None:
    """stateを検証してuidを返す。不正・期限切れなら None。"""
    body, _, signature = state.partition(".")
    if not body or not signature:
        return None
    expected = hmac.new(_get_state_secret().encode(), body.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, signature):
        return None
    try:
        padded = body + "=" * (-len(body) % 4)
        payload = json.loads(base64.urlsafe_b64decode(padded))
    except Exception:
        return None
    if payload.get("exp", 0) < time.time():
        return None
    return payload.get("uid")


def build_install_url(uid: str) -> str:
    if not settings.github_app_slug:
        raise GitHubAppNotConfiguredError("GITHUB_APP_SLUG is not set")
    return (
        f"https://github.com/apps/{settings.github_app_slug}/installations/new"
        f"?state={issue_state(uid)}"
    )
