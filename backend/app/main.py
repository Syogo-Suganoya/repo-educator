from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.github_client import RepositoryNotFoundError, fetch_repository_source, parse_repository_url
from app.quiz_generator import generate_quizzes
from app.sample_quizzes import get_sample_sections
from app.schemas import QuizGenerateRequest, QuizGenerateResponse

app = FastAPI(title="repo-educator API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/api/v1/quiz/generate", response_model=QuizGenerateResponse)
async def generate_quiz(request: QuizGenerateRequest) -> QuizGenerateResponse:
    try:
        owner, repo = parse_repository_url(request.repository_url)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e

    if not settings.vertex_ai_configured:
        sample_sections = get_sample_sections(owner, repo)
        if sample_sections is not None:
            return QuizGenerateResponse(
                repository_id=f"{owner}_{repo}_{request.branch}",
                url=request.repository_url,
                sections=sample_sections,
            )

    try:
        files = await fetch_repository_source(owner, repo, request.branch)
    except RepositoryNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e

    sections = await generate_quizzes(files, request.num_questions, request.focus_language)

    return QuizGenerateResponse(
        repository_id=f"{owner}_{repo}_{request.branch}",
        url=request.repository_url,
        sections=sections,
    )
