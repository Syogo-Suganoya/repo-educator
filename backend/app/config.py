from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    github_token: str = ""
    gcp_project: str = ""
    gcp_location: str = "us-central1"
    google_application_credentials: str = ""

    @property
    def vertex_ai_configured(self) -> bool:
        return bool(self.gcp_project and self.google_application_credentials)

    class Config:
        env_file = ".env"


settings = Settings()
