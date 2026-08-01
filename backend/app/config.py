from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # --- GitHub（未ログイン時の公開リポジトリ取得に使うサーバ共有PAT） ---
    github_token: str = ""

    # --- GitHub App（ログインユーザーのプライベートリポジトリ取得に使う） ---
    github_app_id: str = ""
    github_app_slug: str = ""
    github_app_private_key: str = ""

    # --- Vertex AI ---
    gcp_project: str = ""
    gcp_location: str = "us-central1"
    google_application_credentials: str = ""

    # --- Firebase / Firestore / KMS ---
    firebase_project_id: str = ""
    firestore_enabled: bool = True
    kms_key_name: str = ""

    # --- フロントエンド ---
    # 既定は開発用の全許可。`flutter run -d chrome` はポートが毎回変わるため。
    # 本番では必ず Firebase Hosting のドメインを指定すること（DEPLOY.md 参照）。
    frontend_origin: str = "*"

    # setup-callback の state 署名に使う。未設定ならプロセス起動ごとにランダム生成される。
    state_secret: str = ""

    @property
    def vertex_ai_configured(self) -> bool:
        """Cloud Run ではサービスアカウント権限（ADC）で動くため、プロジェクトIDの有無だけで判定する。

        以前は GOOGLE_APPLICATION_CREDENTIALS の有無を見ていたため、
        鍵ファイルを置かない本番環境ではモック応答が返ってしまっていた。
        """
        return bool(self.gcp_project)

    @property
    def github_app_configured(self) -> bool:
        return bool(self.github_app_id and self.github_app_private_key)

    @property
    def firestore_configured(self) -> bool:
        return bool(self.firestore_enabled and (self.firebase_project_id or self.gcp_project))

    @property
    def firebase_auth_configured(self) -> bool:
        return bool(self.firebase_project_id or self.gcp_project)

    @property
    def allowed_origins(self) -> list[str]:
        """カンマ区切りで複数オリジンを許可できる。空または '*' なら全許可（開発用）。"""
        origins = [o.strip() for o in self.frontend_origin.split(",") if o.strip()]
        return origins or ["*"]

    @property
    def frontend_redirect_base(self) -> str:
        """GitHub App インストール後に戻す先。

        CORS用の '*' はリダイレクト先にできないため、その場合はローカル開発の
        既定ポートに戻す。本番では FRONTEND_ORIGIN に実ドメインを設定すること。
        """
        for origin in self.allowed_origins:
            if origin != "*":
                return origin
        return "http://localhost:5173"

    class Config:
        env_file = ".env"


settings = Settings()
