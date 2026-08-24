import uuid

from app.config import settings
from app.gemini import generate_json
from app.schemas import FeatureSection, Quiz

SYSTEM_INSTRUCTION = """\
あなたは高度なソフトウェアエンジニアリングの教育者です。
提供されたソースコードを深く分析し、まずコードベースを実務上意味のある「機能セクション」
（例: 認証、ルーティング、データモデル、リトライ処理など）にグルーピングしてください。
学習者は後でセクションを選び、そのセクションだけを集中して学習します。

各セクションについて、そのセクションに属するコードから「4択の穴埋めクイズ」を生成してください。

【問題作成のルール】
1. 各クイズには `scenario` として、「実務でこのセクションのどんな作業をするときにこのコードに触ることになるか」
   を1〜2文の具体的な業務シナリオとして記述してください（例:
   「ユーザー認証にOAuthプロバイダを追加する際、このトークン検証処理を変更することになる」）。
2. 問題文には穴埋め対象として `[BLANK]` という文字列を含めてください。
3. 関連するコード断片（スニペット）がある場合は、該当箇所を `____` に置き換えて提示してください。
4. 選択肢（choices）は4つとし、うち1つだけが正解（correct_answer）となるようにしてください。
5. 解説（explanation）には、なぜその選択肢が正しいのか、コードの挙動や設計思想に基づいた詳細な説明を記述してください。
6. セクションの `description` には、そのセクションが実務上どんな役割を担うコード群かを1〜2文で説明してください。
"""

SECTION_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "sections": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "description": {"type": "string"},
                    "quizzes": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "file_path": {"type": "string"},
                                "scenario": {"type": "string"},
                                "question_text": {"type": "string"},
                                "code_snippet": {"type": "string"},
                                "choices": {"type": "array", "items": {"type": "string"}},
                                "correct_answer": {"type": "string"},
                                "explanation": {"type": "string"},
                            },
                            "required": [
                                "file_path",
                                "scenario",
                                "question_text",
                                "choices",
                                "correct_answer",
                                "explanation",
                            ],
                        },
                    },
                },
                "required": ["title", "description", "quizzes"],
            },
        }
    },
}


def _build_prompt(files: list[dict[str, str]], num_questions: int, focus_language: str | None) -> str:
    source_blocks = "\n\n".join(
        f"# {f['path']}\n```\n{f['content']}\n```" for f in files
    )
    focus_note = f"\n特に {focus_language} に関する問題を優先してください。" if focus_language else ""
    return (
        f"以下のソースコードを機能セクションに分類し、合計{num_questions}問のクイズを生成してください。"
        f"{focus_note}\n\n"
        f"{source_blocks}"
    )


def generate_mock_sections(files: list[dict[str, str]], num_questions: int) -> list[FeatureSection]:
    """Gemini未接続時のフォールバック。固定パターンのクイズをファイル数に応じて生成する。"""
    sample_files = files or [{"path": "sample.py", "content": "def add(a, b):\n    return a + b"}]
    quizzes: list[Quiz] = []
    for i in range(num_questions):
        f = sample_files[i % len(sample_files)]
        quizzes.append(
            Quiz(
                quiz_id=str(uuid.uuid4()),
                file_path=f["path"],
                scenario="この関数を含むモジュールに機能追加する際、まず戻り値の計算ロジックを読むことになる。",
                question_text=(
                    f"`{f['path']}` において、この関数の戻り値を決定する演算子は [BLANK] である。"
                ),
                code_snippet="def add(a, b):\n    return a ____ b",
                choices=["+", "-", "*", "/"],
                correct_answer="+",
                explanation=(
                    "この関数は2つの引数を加算して返すため、`+` 演算子が正解です"
                    "（これはGemini未接続時のモック応答です）。"
                ),
            )
        )
    return [
        FeatureSection(
            section_id=str(uuid.uuid4()),
            title="サンプル機能",
            description="Gemini未接続時に表示される仮の機能セクションです。",
            quizzes=quizzes,
        )
    ]


async def generate_quizzes(
    files: list[dict[str, str]], num_questions: int, focus_language: str | None
) -> list[FeatureSection]:
    if not settings.gemini_configured:
        return generate_mock_sections(files, num_questions)

    payload = await generate_json(
        system_instruction=SYSTEM_INSTRUCTION,
        prompt=_build_prompt(files, num_questions, focus_language),
        response_schema=SECTION_RESPONSE_SCHEMA,
    )

    sections: list[FeatureSection] = []
    for section_data in payload.get("sections", []):
        quizzes = [
            Quiz(quiz_id=str(uuid.uuid4()), **quiz_data)
            for quiz_data in section_data.pop("quizzes", [])
        ]
        sections.append(FeatureSection(section_id=str(uuid.uuid4()), quizzes=quizzes, **section_data))
    return sections
