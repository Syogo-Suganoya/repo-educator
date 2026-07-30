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


class QuizGenerateRequest(BaseModel):
    repository_url: str
    branch: str = "main"
    num_questions: int = Field(default=5, ge=1, le=20)
    focus_language: str | None = None


class QuizGenerateResponse(BaseModel):
    repository_id: str
    url: str
    sections: list[FeatureSection]
