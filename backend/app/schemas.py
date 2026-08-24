from pydantic import BaseModel, Field


class Quiz(BaseModel):
    quiz_id: str
    file_path: str
    scenario: str
    question_text: str
    code_snippet: str
    choices: list[str]
    correct_answer: str
    explanation: str


class FeatureSection(BaseModel):
    section_id: str
    title: str
    description: str
    quizzes: list[Quiz]


# --- 逆引きドキュメント -----------------------------------------------------


class CodeRef(BaseModel):
    """ドキュメント本文から参照する実コードの断片。"""

    file_path: str
    snippet: str
    note: str = ""


class DocEntry(BaseModel):
    """逆引きドキュメントの1エントリ。

    kind は「何で引くか」を表す索引の粒度:
      feature … 機能名で引く（例:「認証」「リトライ処理」）
      symbol  … 関数・クラス名で引く（例: `Context.Next()`）
      task    … やりたいことで引く（例:「新しいエンドポイントを追加するには」）
      file    … ファイル名で引く（例: `context.go`）
    """

    doc_id: str
    kind: str
    title: str
    summary: str
    body: str
    file_paths: list[str] = []
    symbols: list[str] = []
    tags: list[str] = []
    code_refs: list[CodeRef] = []
    related_section_titles: list[str] = []


DOC_KINDS = ("feature", "symbol", "task", "file")


class QuizGenerateRequest(BaseModel):
    repository_url: str
    branch: str = "main"
    num_questions: int = Field(default=5, ge=1, le=20)
    focus_language: str | None = None


class QuizGenerateResponse(BaseModel):
    repository_id: str
    url: str
    sections: list[FeatureSection]
    # docs を持たない既存のキャッシュを読んでも壊れないよう、既定値を空リストにする。
    docs: list[DocEntry] = []
    # キャッシュから返したかどうか。動作確認と運用時の切り分けのために返す。
    cached: bool = False


# --- 認証（ID / パスワード） -----------------------------------------------


class RegisterRequest(BaseModel):
    email: str
    password: str = Field(min_length=8)
    display_name: str | None = None


class LoginRequest(BaseModel):
    email: str
    password: str


class AuthResponse(BaseModel):
    """登録・ログインの成功時に返す。フロントはtokenを保存してBearerとして使う。"""

    access_token: str
    uid: str
    email: str
    name: str | None = None


# --- アカウント / GitHub連携 -----------------------------------------------


class MeResponse(BaseModel):
    uid: str
    email: str | None = None
    name: str | None = None
    picture: str | None = None
    github_login: str | None = None
    # PATそのものは絶対に返さない。「設定済みかどうか」だけをフロントに伝える。
    has_github_token: bool = False


class SaveGithubTokenRequest(BaseModel):
    """ユーザーが設定画面で入力したPersonal Access Token。"""

    token: str
    # GET /user から取れたログイン名を添えられればUI表示に使う（任意）。
    github_login: str | None = None


class GithubTokenStatusResponse(BaseModel):
    has_github_token: bool
    github_login: str | None = None


class RepositorySummary(BaseModel):
    full_name: str
    html_url: str
    default_branch: str
    private: bool
    description: str | None = None
    language: str | None = None


class RepositoryListResponse(BaseModel):
    repositories: list[RepositorySummary]


# --- 学習履歴 -------------------------------------------------------------


class AnswerRequest(BaseModel):
    repository_id: str
    quiz_id: str
    correct: bool


class ProgressEntry(BaseModel):
    total_answered: int = 0
    correct_count: int = 0


class ProgressResponse(BaseModel):
    learning_progress: dict[str, ProgressEntry]
