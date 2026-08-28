"""キャッシュとsingle-flightの振る舞いを固定するテスト。

外部（GitHub / Gemini）には一切アクセスしない。
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

    def _check(self, status, remaining=None, authenticated=False, repo_accessible=False):
        _check_response(
            self._response(status, remaining),
            "o",
            "r",
            "main",
            authenticated=authenticated,
            repo_accessible=repo_accessible,
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

    def test_404_authenticated_mentions_token_scope(self):
        # Fine-grained PAT は対象に選んでいないリポジトリも404で隠す。
        # 「URLが違う」と断定せず、トークンの対象設定も疑えるようにする。
        with pytest.raises(RepositoryNotFoundError) as e:
            self._check(404, authenticated=True)
        assert "does not grant access" in str(e.value)

    def test_404_on_accessible_repo_is_branch_not_found(self):
        # リポジトリ情報の取得に成功した後の404は、ブランチ名の誤り以外にありえない。
        # 未認証でも「権限がない」と誤って案内しないこと。
        with pytest.raises(RepositoryNotFoundError) as e:
            self._check(404, repo_accessible=True)
        assert "Branch 'main'" in str(e.value)

    def test_rate_limit_wins_over_accessible_repo(self):
        # レートリミットの判定は他のどの分類よりも先に行われること。
        with pytest.raises(RateLimitedError):
            self._check(403, remaining="0", repo_accessible=True)

    def test_unauthenticated_caller_is_guided_to_register_a_pat(self):
        # 利用者本人のトークンがなければ、404は「存在しない」ではなく
        # 「あなたの権限では読めない」として扱い、PAT登録へ誘導すること。
        with pytest.raises(RepositoryAccessDeniedError):
            self._check(404, authenticated=False)

    def test_success_passes_through(self):
        self._check(200)


class TestRepositoryListing:
    """一覧に出すのはPATで読めるプライベートリポジトリだけであること。

    公開リポジトリはURLを貼れば解析できるので、ここに混ぜると
    「PATがないと辿り着けないもの」という導線の意味が薄れる。
    """

    def _run(self, found):
        import asyncio

        from app import main as m
        from app import store
        from app.auth import AuthUser

        original_list = m.list_my_repositories
        original_tokens = store.list_github_tokens

        async def fake_list(token):
            return found

        async def fake_tokens(uid):
            return [{"id": 1, "github_login": "me", "created_at": None, "token": "t"}]

        m.list_my_repositories = fake_list
        store.list_github_tokens = fake_tokens
        try:
            response = asyncio.run(
                m.list_repositories(AuthUser(uid="u", email="e@example.com", name=None))
            )
            return [r.full_name for r in response.repositories]
        finally:
            m.list_my_repositories = original_list
            store.list_github_tokens = original_tokens

    def _repo(self, name, private):
        return {
            "full_name": name,
            "html_url": f"https://github.com/{name}",
            "private": private,
            "default_branch": "main",
        }

    def test_public_repositories_are_excluded(self):
        names = self._run([self._repo("me/pub", False), self._repo("me/priv", True)])
        assert names == ["me/priv"]

    def test_empty_when_no_private_repositories(self):
        assert self._run([self._repo("me/pub", False)]) == []


class TestTokenResolution:
    """どのトークンでどのリポジトリを読むかの解決。

    総当たりで見つけ、成功した組み合わせを記録し、後日失敗したら記録を捨てて探し直す。
    """

    def _run(self, *, tokens, readable_by, bound_id=None):
        """readable_by … そのリポジトリを読めるトークンの値の集合"""
        import asyncio

        from app import main as m
        from app import store
        from app.auth import AuthUser
        from app.github_client import RepositoryAccessDeniedError, RepositoryMeta

        saved: list[int] = []
        deleted: list[bool] = []

        async def fake_tokens(uid):
            return tokens

        async def fake_get_binding(uid, owner, repo):
            return bound_id

        async def fake_save_binding(uid, owner, repo, token_id):
            saved.append(token_id)

        async def fake_delete_binding(uid, owner, repo):
            deleted.append(True)

        attempts: list[str] = []

        async def fake_meta(owner, repo, branch, token=None):
            attempts.append(token)
            if token not in readable_by:
                raise RepositoryAccessDeniedError("no access")
            return RepositoryMeta(private=True, pushed_at="2026-01-01T00:00:00Z")

        originals = (
            store.list_github_tokens,
            store.get_repo_binding,
            store.save_repo_binding,
            store.delete_repo_binding,
            m.fetch_repository_meta,
        )
        store.list_github_tokens = fake_tokens
        store.get_repo_binding = fake_get_binding
        store.save_repo_binding = fake_save_binding
        store.delete_repo_binding = fake_delete_binding
        m.fetch_repository_meta = fake_meta
        try:
            token, meta = asyncio.run(
                m._resolve_user_token(
                    AuthUser(uid="u", email="e@example.com", name=None), "o", "r", "main"
                )
            )
            return {"token": token, "meta": meta, "saved": saved, "deleted": deleted, "attempts": attempts}
        finally:
            (
                store.list_github_tokens,
                store.get_repo_binding,
                store.save_repo_binding,
                store.delete_repo_binding,
                m.fetch_repository_meta,
            ) = originals

    def _token(self, id, value):
        return {"id": id, "github_login": f"user{id}", "created_at": None, "token": value}

    def test_finds_the_working_token_and_remembers_it(self):
        result = self._run(
            tokens=[self._token(1, "a"), self._token(2, "b")],
            readable_by={"b"},
        )
        assert result["token"] == "b"
        assert result["saved"] == [2]

    def test_bound_token_is_tried_first(self):
        result = self._run(
            tokens=[self._token(1, "a"), self._token(2, "b")],
            readable_by={"a", "b"},
            bound_id=2,
        )
        # 記録済みのものだけで済み、他は試さない
        assert result["attempts"] == ["b"]
        assert result["token"] == "b"
        # 変化がないので保存し直さない
        assert result["saved"] == []

    def test_stale_binding_falls_back_to_search(self):
        # 記録済みのトークンでは読めなくなったが、別のトークンでは読める
        result = self._run(
            tokens=[self._token(1, "a"), self._token(2, "b")],
            readable_by={"a"},
            bound_id=2,
        )
        assert result["token"] == "a"
        assert result["saved"] == [1]

    def test_forgets_binding_when_nothing_works(self):
        result = self._run(
            tokens=[self._token(1, "a")],
            readable_by=set(),
            bound_id=1,
        )
        assert result["token"] is None
        # 次回また総当たりできるよう、古い記録は捨てる
        assert result["deleted"] == [True]

    def test_no_tokens_means_no_access(self):
        result = self._run(tokens=[], readable_by={"a"})
        assert result["token"] is None
        assert result["attempts"] == []


class TestSampleHistory:
    """サンプルカード起点の生成は学習履歴に残さない。

    トップのサンプルは誰が押しても同じキュレーション済みデータで、
    「自分が何を解析したか」の記録としては雑音にしかならない。
    一方、同じリポジトリでもURL入力欄から自分で入力したなら記録する。
    どの入口から来たかはクライアントしか知らないので、リクエストで受け取る。
    """

    def _run(self, *, from_sample):
        from app import main as main_module
        from app.schemas import QuizGenerateRequest

        remembered = []

        async def fake_remember(user, *, request, repository_id, sections):
            remembered.append(repository_id)

        original = main_module._remember_generation
        main_module._remember_generation = fake_remember
        try:
            request = QuizGenerateRequest(
                repository_url="https://github.com/psf/requests",
                branch="main",
                from_sample=from_sample,
            )
            response = asyncio.run(main_module.generate_quiz(request, user=None))
        finally:
            main_module._remember_generation = original

        # どちらの経路でもクイズ自体はサンプルのものが返る
        assert response.sections
        return remembered

    def test_sample_card_is_not_recorded(self):
        assert self._run(from_sample=True) == []

    def test_typed_url_is_recorded(self):
        assert self._run(from_sample=False) == ["psf_requests_main"]
