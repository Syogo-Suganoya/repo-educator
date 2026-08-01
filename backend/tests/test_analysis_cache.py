"""キャッシュとsingle-flightの振る舞いを固定するテスト。

外部（GitHub / Vertex AI）には一切アクセスしない。
実行: docker compose exec backend python -m pytest tests -q
"""

import asyncio

import pytest

from app import analysis_cache
from app.analysis_cache import (
    AnalysisResult,
    HeadRef,
    cache_key,
    head_key,
    is_unchanged,
    memory_clear,
    memory_get,
    memory_put,
)
from app.github_client import (
    RateLimitedError,
    RepositoryAccessDeniedError,
    RepositoryNotFoundError,
    _check_response,
)


@pytest.fixture(autouse=True)
def _clear():
    memory_clear()
    yield
    memory_clear()


def _result(private=False, counts=(5,)):
    return AnalysisResult(
        private=private,
        docs=[],
        sections_by_count={c: [] for c in counts},
    )


class TestMemoryCache:
    def test_put_then_get(self):
        memory_put("k", _result())
        assert memory_get("k") is not None

    def test_miss_returns_none(self):
        assert memory_get("absent") is None

    def test_expired_entry_is_dropped(self, monkeypatch):
        memory_put("k", _result())
        # TTLを過ぎた状態を再現する
        monkeypatch.setattr(analysis_cache, "_MEMORY_TTL_SECONDS", -1)
        assert memory_get("k") is None

    def test_evicts_oldest_when_full(self, monkeypatch):
        monkeypatch.setattr(analysis_cache, "_MEMORY_MAX_ENTRIES", 3)
        for i in range(5):
            memory_put(f"k{i}", _result())
        # 上限を超えて増え続けないこと
        assert len(analysis_cache._memory) <= 3
        # 最後に入れたものは残っていること
        assert memory_get("k4") is not None

    def test_cache_key_includes_commit_sha(self):
        # ブランチが進んだら別のキーになる＝古い結果が返り続けない
        assert cache_key("o", "r", "sha1") != cache_key("o", "r", "sha2")


class TestSectionsByCount:
    def test_sections_are_kept_per_question_count(self):
        result = _result(counts=(5, 10))
        assert result.sections_for(5) is not None
        assert result.sections_for(10) is not None
        # 生成していない出題数はミスになる
        assert result.sections_for(7) is None


class TestPushedAtFastPath:
    """更新日時による足切り。

    pushed_at はリポジトリ全体の値で対象ブランチ固有ではないため、
    「変わっていない」ことの確認にだけ使い、再生成の判断には使わない。
    判断がつかない場合は必ず False（＝SHAを確認しに行く）に倒す。
    """

    def test_same_pushed_at_means_unchanged(self):
        known = HeadRef(commit_sha="abc", pushed_at="2026-07-01T00:00:00Z")
        assert is_unchanged(known, "2026-07-01T00:00:00Z") is True

    def test_newer_pushed_at_is_not_trusted_as_unchanged(self):
        known = HeadRef(commit_sha="abc", pushed_at="2026-07-01T00:00:00Z")
        assert is_unchanged(known, "2026-07-02T00:00:00Z") is False

    def test_no_previous_record_forces_a_check(self):
        assert is_unchanged(None, "2026-07-01T00:00:00Z") is False

    def test_missing_timestamp_forces_a_check(self):
        # GitHubがpushed_atを返さないケースでも、古い結果を返さない側に倒す
        known = HeadRef(commit_sha="abc", pushed_at=None)
        assert is_unchanged(known, "2026-07-01T00:00:00Z") is False
        assert is_unchanged(HeadRef("abc", "2026-07-01T00:00:00Z"), None) is False

    def test_head_key_is_per_branch(self):
        # 同じリポジトリでもブランチごとに別々に追跡する
        assert head_key("o", "r", "main") != head_key("o", "r", "develop")

    def test_head_memory_roundtrip(self):
        key = head_key("o", "r", "main")
        analysis_cache.head_memory_put(key, HeadRef("abc", "2026-07-01T00:00:00Z"))
        assert analysis_cache.head_memory_get(key).commit_sha == "abc"

    def test_head_memory_is_cleared_with_analysis_memory(self):
        analysis_cache.head_memory_put("k", HeadRef("abc", None))
        memory_clear()
        assert analysis_cache.head_memory_get("k") is None


class TestSingleFlight:
    @pytest.mark.asyncio
    async def test_concurrent_calls_run_factory_once(self):
        calls = 0

        async def factory():
            nonlocal calls
            calls += 1
            await asyncio.sleep(0.05)
            return "value"

        results = await asyncio.gather(
            *[analysis_cache.run_once("same", factory) for _ in range(5)]
        )

        assert calls == 1
        assert results == ["value"] * 5
        assert analysis_cache.inflight_count() == 0

    @pytest.mark.asyncio
    async def test_different_keys_run_independently(self):
        calls = 0

        async def factory():
            nonlocal calls
            calls += 1
            return calls

        await asyncio.gather(
            analysis_cache.run_once("a", factory),
            analysis_cache.run_once("b", factory),
        )
        assert calls == 2

    @pytest.mark.asyncio
    async def test_failure_propagates_and_does_not_stick(self):
        attempts = 0

        async def failing():
            nonlocal attempts
            attempts += 1
            raise RuntimeError("boom")

        with pytest.raises(RuntimeError):
            await analysis_cache.run_once("k", failing)

        # 失敗結果は保持せず、次の呼び出しでやり直せること
        with pytest.raises(RuntimeError):
            await analysis_cache.run_once("k", failing)

        assert attempts == 2
        assert analysis_cache.inflight_count() == 0


class TestErrorClassification:
    """GitHubは権限不足にもレートリミットにも403を返すため、取り違えないこと。"""

    def _response(self, status, remaining=None):
        import httpx

        headers = {} if remaining is None else {"x-ratelimit-remaining": remaining}
        return httpx.Response(status, headers=headers)

    def _check(self, status, remaining=None, authenticated=False):
        _check_response(
            self._response(status, remaining), "o", "r", "main", authenticated=authenticated
        )

    def test_rate_limit_is_not_access_denied(self):
        with pytest.raises(RateLimitedError):
            self._check(403, remaining="0")

    def test_429_is_rate_limit(self):
        with pytest.raises(RateLimitedError):
            self._check(429, remaining="0")

    def test_403_with_quota_left_is_access_denied(self):
        with pytest.raises(RepositoryAccessDeniedError):
            self._check(403, remaining="42")

    def test_404_unauthenticated_is_access_denied(self):
        # 未認証には「存在しない」と「権限がない」の区別がつかないため、
        # インストールを促せる側に倒す
        with pytest.raises(RepositoryAccessDeniedError):
            self._check(404)

    def test_404_authenticated_is_not_found(self):
        with pytest.raises(RepositoryNotFoundError):
            self._check(404, authenticated=True)

    def test_success_passes_through(self):
        self._check(200)
