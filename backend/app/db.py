"""PostgreSQL（互換）への接続とテーブル定義。

ローカル開発はDocker Composeのpostgresコンテナ、本番はNeon等の
マネージドPostgresを想定。接続文字列（DATABASE_URL）を変えるだけで両対応する。

DATABASE_URL が未設定の場合はエンジンを作らない。ログイン・履歴・解析結果の
永続キャッシュは無効になるが、公開リポジトリの学習自体はメモリキャッシュのみで動く。
"""

import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, Boolean, DateTime, ForeignKey, Integer, LargeBinary, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

from app.config import settings


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    hashed_password: Mapped[str] = mapped_column(String(255))
    display_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)

    # ユーザーが設定画面で入力したGitHub PAT（Fernetで暗号化済み）。
    # サインインに使うプロバイダとは無関係の、本人が発行した個別トークン。
    github_login: Mapped[str | None] = mapped_column(String(255), nullable=True)
    github_token_encrypted: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)

    progress: Mapped[list["LearningProgress"]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )


class LearningProgress(Base):
    """ユーザーごと・リポジトリごとの解答履歴。"""

    __tablename__ = "learning_progress"
    __table_args__ = (UniqueConstraint("user_id", "repository_id", name="uq_progress_user_repo"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id"), index=True)
    repository_id: Mapped[str] = mapped_column(String(512))
    total_answered: Mapped[int] = mapped_column(Integer, default=0)
    correct_count: Mapped[int] = mapped_column(Integer, default=0)
    last_accessed: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, onupdate=_utcnow)

    user: Mapped[User] = relationship(back_populates="progress")


class RepositoryHead(Base):
    """ブランチごとに「最後に確認した状態」を保持する。

    pushed_atが前回と同じなら、コミットSHAの再取得を省ける
    （詳細はREADME「2.4 冗長な処理の排除」を参照）。
    """

    __tablename__ = "repository_heads"
    __table_args__ = (UniqueConstraint("owner", "repo", "branch", name="uq_head_owner_repo_branch"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    owner: Mapped[str] = mapped_column(String(255))
    repo: Mapped[str] = mapped_column(String(255))
    branch: Mapped[str] = mapped_column(String(255))
    commit_sha: Mapped[str] = mapped_column(String(64))
    pushed_at: Mapped[str | None] = mapped_column(String(64), nullable=True)
    checked_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, onupdate=_utcnow)


class AnalysisCache(Base):
    """クイズ・ドキュメントの解析結果キャッシュ（コミットSHA単位）。"""

    __tablename__ = "analysis_cache"
    __table_args__ = (UniqueConstraint("owner", "repo", "commit_sha", name="uq_cache_owner_repo_sha"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    owner: Mapped[str] = mapped_column(String(255))
    repo: Mapped[str] = mapped_column(String(255))
    commit_sha: Mapped[str] = mapped_column(String(64))
    url: Mapped[str] = mapped_column(String(1024))
    visibility: Mapped[str] = mapped_column(String(16))
    docs: Mapped[list] = mapped_column(JSON, default=list)
    # 出題数(int)ごとのセクション一覧。JSONのキーは文字列になる。
    sections_by_count: Mapped[dict] = mapped_column(JSON, default=dict)
    analyzed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, onupdate=_utcnow)


_engine = None
_session_factory: async_sessionmaker[AsyncSession] | None = None


def _get_engine():
    global _engine
    if _engine is None:
        _engine = create_async_engine(settings.database_url, pool_pre_ping=True)
    return _engine


def get_session_factory() -> async_sessionmaker[AsyncSession]:
    global _session_factory
    if _session_factory is None:
        _session_factory = async_sessionmaker(_get_engine(), expire_on_commit=False)
    return _session_factory


async def init_models() -> None:
    """テーブルが無ければ作成する。

    このプロジェクトの規模では Alembic 等のマイグレーションツールは導入せず、
    起動時に create_all するだけの単純な構成にしている。
    """
    if not settings.db_configured:
        return
    async with _get_engine().begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
