import re
from dataclasses import dataclass

import httpx

from app.config import settings

TARGET_EXTENSIONS = {".py", ".js", ".ts", ".tsx", ".jsx", ".go", ".java", ".rb", ".rs"}
MAX_TOTAL_CHARS = 60_000
MAX_FILE_CHARS = 8_000

GITHUB_API = "https://api.github.com"


class RepositoryNotFoundError(Exception):
    """リポジトリまたはブランチが存在しない。"""


class RepositoryAccessDeniedError(Exception):
    """リポジトリは存在しうるが、現在の認証情報では読めない。

    GitHubはプライベートリポジトリの存在を隠すため、権限がない場合も404を返す。
    未認証・未インストールのユーザーにはこちらとして扱い、
    「アプリをインストールしてください」と案内できるようにする。
    """


class RateLimitedError(Exception):
    """GitHub APIのレートリミットに達した。

    GitHubはレートリミットにも403を返すため、権限不足と区別せずに扱うと
    「アクセス権がありません」という誤った案内をしてしまう。
    未認証は60req/hと厳しく、実際に到達しうるので明示的に分けている。
    """

    def __init__(self, reset_epoch: int | None = None):
        self.reset_epoch = reset_epoch
        super().__init__("GitHub API rate limit exceeded")


@dataclass
class RepositoryMeta:
    """リポジトリの基本情報。GitHub API 1回で取れる。

    pushed_at は「リポジトリのどこかに push があった時刻」で、
    **対象ブランチが変わったかどうかは表さない**（別ブランチへのpushでも進む）。
    そのため「前回と同じ＝確実に変わっていない」という足切りにのみ使い、
    再生成の判断には使わない。
    """

    private: bool
    pushed_at: str | None


@dataclass
class RepositoryRef:
    """リポジトリの同一性を決める最小限の情報。

    commit_sha がキャッシュのキーになる。ソース本体を取得する前にこれだけを
    先に解決することで、キャッシュヒット時にファイルを1つもダウンロードせずに済む。
    """

    owner: str
    repo: str
    commit_sha: str
    private: bool


class InvalidTokenError(Exception):
    """入力されたPersonal Access TokenをGitHubが受け付けなかった。"""


async def verify_user_token(token: str) -> str | None:
    """PATが有効か確認し、有効なら GitHub のログイン名を返す。

    ユーザーが設定画面で貼り付けた直後に呼び、無効な値をそのまま
    保存してしまわないようにする。
    """
    async with httpx.AsyncClient(timeout=15.0) as client:
        resp = await client.get(
            f"{GITHUB_API}/user",
            headers={"Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}"},
        )
    if resp.status_code == 401:
        raise InvalidTokenError("The provided GitHub token is invalid or has expired")
    resp.raise_for_status()
    return resp.json().get("login")


async def list_my_repositories(token: str) -> list[dict]:
    """PATを持つ本人がアクセスできるリポジトリ一覧（プライベート含む）。

    保存済みの
    ユーザー自身のトークンでそのまま `GET /user/repos` を叩くだけでよい。
    """
    repositories: list[dict] = []
    async with httpx.AsyncClient(timeout=20.0) as client:
        page = 1
        while True:
            resp = await client.get(
                f"{GITHUB_API}/user/repos",
                headers={
                    "Accept": "application/vnd.github+json",
                    "Authorization": f"Bearer {token}",
                },
                params={"per_page": 100, "page": page, "sort": "pushed", "affiliation": "owner,collaborator,organization_member"},
            )
            if resp.status_code == 401:
                raise InvalidTokenError("The provided GitHub token is invalid or has expired")
            resp.raise_for_status()
            chunk = resp.json()
            repositories.extend(chunk)
            if len(chunk) < 100:
                break
            page += 1
    return repositories


def parse_repository_url(repository_url: str) -> tuple[str, str]:
    match = re.search(r"github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", repository_url.strip())
    if not match:
        raise ValueError(f"Invalid GitHub repository URL: {repository_url}")
    return match.group(1), match.group(2)


def _auth_headers(token: str | None) -> dict[str, str]:
    """呼び出し元が渡したトークンを優先し、なければサーバ共有のPATにフォールバックする。

    未ログインの公開リポジトリ利用では token=None となり、従来通りの挙動になる。
    """
    headers = {"Accept": "application/vnd.github+json"}
    effective_token = token or settings.github_token
    if effective_token:
        headers["Authorization"] = f"Bearer {effective_token}"
    return headers


def _check_response(
    response: httpx.Response,
    owner: str,
    repo: str,
    branch: str,
    *,
    authenticated: bool,
    repo_accessible: bool = False,
) -> None:
    """GitHubのエラー応答を、案内可能な3種類の例外に振り分ける。

    GitHubはレートリミットにも権限不足にも403を返すため、
    残リクエスト数ヘッダーを見て区別する。

    `authenticated` は「利用者自身のトークンで問い合わせたか」を表す。
    サーバ共有トークン（レートリミット緩和用）でAuthorizationが付いていても、
    それは利用者の権限ではないため False として扱う。

    また、非公開リポジトリは未認証だと404で隠されるため、
    「存在しない」と「権限がない」は応答だけでは区別できない。
    ただし repo_accessible=True（リポジトリ自体は既に読めている）の場合は
    権限の問題ではありえないので、ブランチ名の誤りとして扱う。
    """
    if response.status_code not in (403, 404, 422, 429):
        return

    remaining = response.headers.get("x-ratelimit-remaining")
    if response.status_code in (403, 429) and remaining == "0":
        reset = response.headers.get("x-ratelimit-reset")
        raise RateLimitedError(int(reset) if reset and reset.isdigit() else None)

    if repo_accessible:
        raise RepositoryNotFoundError(f"Branch '{branch}' was not found in {owner}/{repo}")
    if authenticated:
        # Fine-grained PAT は「対象に選んでいないリポジトリ」も404で隠す。
        # URLの誤りと権限不足を応答から区別できないため、両方の可能性を伝える。
        raise RepositoryNotFoundError(
            f"{owner}/{repo} not found, or your GitHub token does not grant access to it"
        )
    # 利用者自身のトークンがない場合。サーバ共有トークンで問い合わせていても、
    # 「あなたの権限では読めない」ことに変わりはないので、PAT登録へ誘導する。
    raise RepositoryAccessDeniedError(
        f"{owner}/{repo}@{branch} not found or not accessible without authentication"
    )


async def fetch_repository_meta(
    owner: str,
    repo: str,
    branch: str,
    token: str | None = None,
) -> RepositoryMeta:
    """公開/非公開と最終push時刻を取得する。GitHub API 1回。

    前回見た pushed_at と変化がなければ、コミットSHAの問い合わせすら省ける。
    """
    headers = _auth_headers(token)
    # サーバ共有トークンで付いたAuthorizationは「この利用者の権限」ではない。
    # 案内の分岐は利用者自身がトークンを持っているかで決める。
    authenticated = token is not None

    async with httpx.AsyncClient(timeout=20.0, headers=headers) as client:
        resp = await client.get(f"{GITHUB_API}/repos/{owner}/{repo}")
        _check_response(resp, owner, repo, branch, authenticated=authenticated)
        resp.raise_for_status()
        payload = resp.json()

    return RepositoryMeta(
        private=bool(payload.get("private", False)),
        pushed_at=payload.get("pushed_at"),
    )


async def resolve_commit_sha(
    owner: str,
    repo: str,
    branch: str,
    token: str | None = None,
) -> str:
    """対象ブランチの先頭コミットSHAを取得する。GitHub API 1回。

    キャッシュの鍵になる値。**push があったと分かったときだけ呼ぶ**ことで、
    変化のないリポジトリへの再訪問ではこの1回も省ける。
    """
    headers = _auth_headers(token)
    # サーバ共有トークンで付いたAuthorizationは「この利用者の権限」ではない。
    # 案内の分岐は利用者自身がトークンを持っているかで決める。
    authenticated = token is not None

    async with httpx.AsyncClient(timeout=20.0, headers=headers) as client:
        resp = await client.get(f"{GITHUB_API}/repos/{owner}/{repo}/commits/{branch}")
        # ここへ来る時点でリポジトリ情報の取得は成功しているため、
        # 失敗するとすればブランチ名が原因である。
        _check_response(
            resp, owner, repo, branch, authenticated=authenticated, repo_accessible=True
        )
        resp.raise_for_status()
        return resp.json().get("sha", branch)


async def fetch_repository_files(
    ref: RepositoryRef,
    branch: str,
    token: str | None = None,
) -> list[dict[str, str]]:
    """リポジトリのツリーを辿り、対象拡張子のソース本文を取得する。

    ファイル本文は Blobs API から取得する。raw.githubusercontent.com は
    Authorizationヘッダを受け付けずプライベートリポジトリを読めないため使わない。

    ファイル数に比例してGitHub APIを消費するため、
    **キャッシュがミスしたときにだけ呼ぶこと。**
    """
    headers = _auth_headers(token)
    # サーバ共有トークンで付いたAuthorizationは「この利用者の権限」ではない。
    # 案内の分岐は利用者自身がトークンを持っているかで決める。
    authenticated = token is not None
    owner, repo = ref.owner, ref.repo

    async with httpx.AsyncClient(timeout=20.0, headers=headers) as client:
        # ブランチ名ではなく解決済みのコミットSHAを指定する。
        # 解決からファイル取得までの間にブランチが進んでも、キャッシュキーと中身がずれない。
        tree_resp = await client.get(
            f"{GITHUB_API}/repos/{owner}/{repo}/git/trees/{ref.commit_sha}",
            params={"recursive": "1"},
        )
        _check_response(tree_resp, owner, repo, branch, authenticated=authenticated)
        tree_resp.raise_for_status()

        candidates = [
            item
            for item in tree_resp.json().get("tree", [])
            if item.get("type") == "blob"
            and item.get("sha")
            and any(item["path"].endswith(ext) for ext in TARGET_EXTENSIONS)
        ]

        files: list[dict[str, str]] = []
        total_chars = 0
        for item in candidates:
            if total_chars >= MAX_TOTAL_CHARS:
                break
            blob_resp = await client.get(
                f"{GITHUB_API}/repos/{owner}/{repo}/git/blobs/{item['sha']}",
                headers={"Accept": "application/vnd.github.raw"},
            )
            if blob_resp.status_code != 200:
                continue
            content = blob_resp.text[:MAX_FILE_CHARS]
            files.append({"path": item["path"], "content": content})
            total_chars += len(content)

        return files
