import re

import httpx

from app.config import settings

TARGET_EXTENSIONS = {".py", ".js", ".ts", ".tsx", ".jsx", ".go", ".java", ".rb", ".rs"}
MAX_TOTAL_CHARS = 60_000
MAX_FILE_CHARS = 8_000


class RepositoryNotFoundError(Exception):
    pass


def parse_repository_url(repository_url: str) -> tuple[str, str]:
    match = re.search(r"github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", repository_url.strip())
    if not match:
        raise ValueError(f"Invalid GitHub repository URL: {repository_url}")
    return match.group(1), match.group(2)


def _auth_headers() -> dict[str, str]:
    headers = {"Accept": "application/vnd.github+json"}
    if settings.github_token:
        headers["Authorization"] = f"Bearer {settings.github_token}"
    return headers


async def fetch_repository_source(owner: str, repo: str, branch: str) -> list[dict[str, str]]:
    """Recursively walk the repo tree via the GitHub API and return target source files."""
    async with httpx.AsyncClient(timeout=20.0, headers=_auth_headers()) as client:
        tree_resp = await client.get(
            f"https://api.github.com/repos/{owner}/{repo}/git/trees/{branch}",
            params={"recursive": "1"},
        )
        if tree_resp.status_code == 404:
            raise RepositoryNotFoundError(f"{owner}/{repo}@{branch} not found")
        tree_resp.raise_for_status()
        tree = tree_resp.json().get("tree", [])

        candidate_paths = [
            item["path"]
            for item in tree
            if item.get("type") == "blob"
            and any(item["path"].endswith(ext) for ext in TARGET_EXTENSIONS)
        ]

        files: list[dict[str, str]] = []
        total_chars = 0
        for path in candidate_paths:
            if total_chars >= MAX_TOTAL_CHARS:
                break
            raw_resp = await client.get(
                f"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}"
            )
            if raw_resp.status_code != 200:
                continue
            content = raw_resp.text[:MAX_FILE_CHARS]
            files.append({"path": path, "content": content})
            total_chars += len(content)

        return files
