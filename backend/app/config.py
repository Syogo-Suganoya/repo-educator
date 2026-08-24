from typing import ClassVar

from pydantic import Field
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # --- GitHub（未ログイン時の公開リポジトリ取得に使うサーバ共有PAT） ---
    #
    # これはユーザー個別のトークンとは別物。ユーザー自身のPATは環境変数には置かず、
    # ログイン後に本人が入力してDBに暗号化保存する（store.save_github_user_token）。
    github_token: str = ""

    # --- Gemini（Gemini Developer API。APIキー1本で使う。Vertex AI は使わない） ---
    #
    # GCPプロジェクト・IAMを経由するVertex AI ではなく、単体のAPIキーで
    # ai.google.dev のGemini Developer APIを直接呼ぶ。DB等とは
    # 完全に独立しており、DATABASE_URL が空でもGeminiだけは動く。
    gemini_api_key: str = ""

    # Geminiのモデルは定期的に廃止される（1.5系は既に404、2.5系も2026-10-16に終了）。
    # 次の廃止時にコード変更が要らないよう、環境変数で差し替えられるようにしている。
    # 空文字で上書きされても既定値に戻るよう、参照は gemini_model プロパティ経由で行う。
    gemini_model_override: str = Field(default="", alias="GEMINI_MODEL")

    DEFAULT_GEMINI_MODEL: ClassVar[str] = "gemini-3.5-flash"

    @property
    def gemini_model(self) -> str:
        return self.gemini_model_override.strip() or self.DEFAULT_GEMINI_MODEL

    @property
    def gemini_configured(self) -> bool:
        return bool(self.gemini_api_key)

    # --- データベース（PostgreSQL互換。Docker Composeのローカルコンテナでも
    #     Neon等のマネージドサービスでも、接続文字列を変えるだけで動く） ---
    #
    # 例:
    #   ローカル: postgresql+asyncpg://repo_educator:repo_educator@db:5432/repo_educator
    #   Neon    : postgresql+asyncpg://user:pass@ep-xxxx.neon.tech/dbname?ssl=require
    database_url: str = ""

    # --- 認証（自前実装。Firebase/GCPには依存しない） ---
    #
    # JWTの署名鍵。空だと認証機能自体が無効になる（公開リポジトリの利用は継続できる）。
    jwt_secret: str = ""
    jwt_expires_days: int = 30

    # ユーザーが入力したGitHub PATの暗号化鍵（Fernet用）。
    # `cryptography.fernet.Fernet.generate_key()` で生成した値を設定する。
    encryption_key: str = ""

    # --- フロントエンド ---
    # 既定は開発用の全許可。`flutter run -d chrome` はポートが毎回変わるため。
    # 本番では必ずフロントエンドの配信ドメインを指定すること（DEPLOY.md 参照）。
    frontend_origin: str = "*"

    @property
    def db_configured(self) -> bool:
        return bool(self.database_url)

    @property
    def auth_configured(self) -> bool:
        """ログイン機能全体の有効条件。DBがなければユーザーを永続化できない。"""
        return bool(self.jwt_secret and self.database_url)

    @property
    def allowed_origins(self) -> list[str]:
        """カンマ区切りで複数オリジンを許可できる。空または '*' なら全許可（開発用）。"""
        origins = [o.strip() for o in self.frontend_origin.split(",") if o.strip()]
        return origins or ["*"]

    class Config:
        env_file = ".env"


settings = Settings()
