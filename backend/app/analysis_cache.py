"""解析結果のキャッシュと、同時リクエストの単一実行。

同じリポジトリ・同じコミットに対する解析は何度やっても同じ結果になるため、
以下の3段構えで冗長な処理を避ける。

  1. プロセス内メモリキャッシュ … 最も速い。Firestore未設定でも効く
  2. Firestore              … プロセスやインスタンスをまたいで共有される
  3. single-flight          … 同時に走る同一リクエストを1本にまとめる

Cloud Run は複数インスタンスに分散するため、メモリキャッシュだけでは
ユーザー間の共有が保証されない。逆にFirestoreだけだと毎回読み取りが発生する。
両方を重ねることで、どちらの環境でも冗長にならないようにしている。
"""

import asyncio
import logging
import time
from dataclasses import dataclass, field

from app.schemas import DocEntry, FeatureSection

logger = logging.getLogger(__name__)

# メモリキャッシュの保持時間と上限。
# コミットSHAをキーにしているため内容が古くなることはなく、
# TTLはあくまでメモリを解放するためのもの。
_MEMORY_TTL_SECONDS = 30 * 60
_MEMORY_MAX_ENTRIES = 64


@dataclass
class AnalysisResult:
    """1リポジトリ・1コミット分の解析結果。

    docs は出題数に依存しないため常に共有できる。
    sections は出題数ごとに異なるため、出題数をキーに持ち分ける。
    """

    private: bool
    docs: list[DocEntry] = field(default_factory=list)
    sections_by_count: dict[int, list[FeatureSection]] = field(default_factory=dict)

    def sections_for(self, num_questions: int) -> list[FeatureSection] | None:
        return self.sections_by_count.get(num_questions)


@dataclass
class HeadRef:
    """あるブランチについて「最後に見たときの状態」。

    pushed_at はGitHubが返した値をそのまま保持する。
    自前の解析時刻と突き合わせると時計のずれで誤判定しうるため、
    **比較はGitHubのpushed_at同士で行う。**
    """

    commit_sha: str
    pushed_at: str | None


def cache_key(owner: str, repo: str, commit_sha: str) -> str:
    return f"{owner}_{repo}_{commit_sha}"


def head_key(owner: str, repo: str, branch: str) -> str:
    return f"{owner}_{repo}_{branch}"


def is_unchanged(known: HeadRef | None, pushed_at: str | None) -> bool:
    """前回見たときから push がないと確実に言えるか。

    真を返すのは「変わっていないと断言できる」ときだけ。判断がつかない場合は
    偽を返してコミットSHAを確認しにいく（誤って古い結果を返さないため）。
    """
    if known is None or known.pushed_at is None or pushed_at is None:
        return False
    return known.pushed_at == pushed_at


# --- プロセス内メモリキャッシュ -------------------------------------------

_memory: dict[str, tuple[AnalysisResult, float]] = {}


def memory_get(key: str) -> AnalysisResult | None:
    entry = _memory.get(key)
    if entry is None:
        return None
    result, stored_at = entry
    if time.monotonic() - stored_at > _MEMORY_TTL_SECONDS:
        _memory.pop(key, None)
        return None
    return result


def memory_put(key: str, result: AnalysisResult) -> None:
    # 上限を超えたら最も古いものから捨てる。
    if len(_memory) >= _MEMORY_MAX_ENTRIES and key not in _memory:
        oldest = min(_memory, key=lambda k: _memory[k][1])
        _memory.pop(oldest, None)
    _memory[key] = (result, time.monotonic())


def memory_clear() -> None:
    """テスト用。"""
    _memory.clear()
    _head_memory.clear()


# --- ブランチ先頭のポインタ（プロセス内） ---------------------------------

_head_memory: dict[str, HeadRef] = {}


def head_memory_get(key: str) -> HeadRef | None:
    return _head_memory.get(key)


def head_memory_put(key: str, head: HeadRef) -> None:
    if len(_head_memory) >= _MEMORY_MAX_ENTRIES and key not in _head_memory:
        _head_memory.pop(next(iter(_head_memory)), None)
    _head_memory[key] = head


# --- single-flight --------------------------------------------------------

_inflight: dict[str, asyncio.Task] = {}


async def run_once(key: str, factory):
    """同じキーの処理が既に走っていれば、その完了を待って結果を共有する。

    異なるユーザーが同じリポジトリを同時に開いたとき、Geminiの呼び出しが
    人数分走るのを防ぐ。先行タスクが例外で終わった場合、待っていた側にも
    同じ例外が伝播する（各自がリトライできるよう、失敗結果は保持しない）。
    """
    existing = _inflight.get(key)
    if existing is not None:
        logger.info("Joining in-flight analysis for %s", key)
        return await asyncio.shield(existing)

    task = asyncio.create_task(factory())
    _inflight[key] = task
    try:
        return await asyncio.shield(task)
    finally:
        # 待っていた側が先に片付けても二重削除にならないよう、同一性を確認する。
        if _inflight.get(key) is task:
            _inflight.pop(key, None)


def inflight_count() -> int:
    """テスト・診断用。"""
    return len(_inflight)
