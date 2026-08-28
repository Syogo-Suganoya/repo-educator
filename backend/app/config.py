from typing import ClassVar

from pydantic import Field
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # --- Gemini（Gemini Developer API。APIキー1本で使う） ---
    #
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
    #
    # 参照は database_url プロパティ経由で行う。マネージドサービスが配る生の
    # 接続文字列をそのまま入れても動くよう、非同期ドライバ向けに正規化するため。
    database_url_raw: str = Field(default="", alias="DATABASE_URL")

    @property
    def database_url(self) -> str:
        """非同期ドライバ（asyncpg）で使える形に整えた接続文字列を返す。

        Neon等が配るのは `postgresql://...?sslmode=require` という同期ドライバ向けの
        形式で、そのまま渡すとSQLAlchemyがpsycopg2を選び、未インストールで起動に失敗する。
        本番で気づきにくい割に直し方が一意なので、ここで吸収する。
        """
        url = self.database_url_raw.strip()
        if not url:
            return ""
        if url.startswith("postgres://"):
            url = "postgresql://" + url[len("postgres://") :]
        if url.startswith("postgresql://"):
            url = "postgresql+asyncpg://" + url[len("postgresql://") :]

        base, _, query = url.partition("?")
        if not query:
            return url

        # asyncpg は psycopg2 向けのクエリを解さない。
        #   sslmode        → 等価な ssl に読み替える
        #   channel_binding → asyncpg に無い項目なので落とす（Neonの文字列に付いてくる）
        kept = []
        for part in query.split("&"):
            if not part:
                continue
            key, sep, value = part.partition("=")
            if key == "channel_binding":
                continue
            if key == "sslmode":
                key = "ssl"
            kept.append(f"{key}{sep}{value}")
        return f"{base}?{'&'.join(kept)}" if kept else base

    # --- 認証（メールアドレス + パスワード / JWT） ---
    #
    # JWTの署名鍵。空だと認証機能自体が無効になる（公開リポジトリの利用は継続できる）。
    jwt_secret: str = ""
    jwt_expires_days: int = 30

    # ユーザーが入力したGitHub PATの暗号化鍵（Fernet用）。
    # `cryptography.fernet.Fernet.generate_key()` で生成した値を設定する。
    encryption_key: str = ""

    # --- フロントエンド ---
    # 既定は開発用の全許可。`flutter run -d chrome` はポートが毎回変わるため。
    # 本番では必ずフロントエンドの配信ドメインを指定すること。
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
