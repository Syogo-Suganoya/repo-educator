"""逆引きドキュメントの生成。

quiz_generator.py と対になるモジュール。同じソースコードから、
「機能名・関数名・やりたいこと・ファイル名」の4通りで引けるドキュメント索引を作る。

クイズとは別のGemini呼び出しにしているのは、
1回の呼び出しに詰め込むと出力トークン上限でJSONが途中で切れやすいため。
"""

import json
import uuid

from app.config import settings
from app.schemas import CodeRef, DocEntry

SYSTEM_INSTRUCTION = """\
あなたは高度なソフトウェアエンジニアリングの教育者です。
提供されたソースコードを分析し、開発者が「知りたいことから引ける」逆引きドキュメントを作成してください。

【索引の4つの粒度】
各エントリには `kind` を必ず指定してください。

1. `feature` … 機能名から引く。例:「認証」「リトライ処理」「ルーティング」
2. `symbol`  … 関数名・クラス名から引く。例:「Context.Next()」「Session」
3. `task`    … やりたいことから引く。例:「新しいエンドポイントを追加するには」
4. `file`    … ファイル名から引く。例:「context.go」

【件数の目安】
`feature` を3〜5件、`symbol` を4〜8件、`task` を3〜5件、`file` を3〜6件。
4種類すべてを必ず含めてください。

【各フィールドの書き方】
- `title` … 検索でそのまま入力されうる語にしてください。`symbol` なら実際の識別子、
  `file` なら実際のファイル名（パスではなくファイル名）を使ってください。
- `summary` … 1〜2文。検索結果の一覧に表示されるため、これだけで当たりかどうか判断できるように。
- `body` … 本文。仕組み・設計意図・注意点を説明します。段落は空行2つで区切ってください。
- `tags` … **検索のヒット率を左右する最重要フィールドです。** 日本語と英語の両方の呼び名、
  略称、関連語を入れてください。例: 認証のエントリなら
  ["認証", "ログイン", "サインイン", "auth", "authentication", "login", "credential"]
- `symbols` … 関連する関数名・クラス名。`kind` が `symbol` 以外でも入れてください。
- `code_refs` … 実際のコード断片。`note` にはその断片が何をしているかを1文で書いてください。
  **クイズと違い、コードは穴埋めにせず原文のまま引用してください。**
- `related_section_titles` … このエントリに対応する機能セクション名（クイズ側と行き来するため）。
"""

DOC_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "docs": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "kind": {
                        "type": "string",
                        "enum": ["feature", "symbol", "task", "file"],
                    },
                    "title": {"type": "string"},
                    "summary": {"type": "string"},
                    "body": {"type": "string"},
                    "file_paths": {"type": "array", "items": {"type": "string"}},
                    "symbols": {"type": "array", "items": {"type": "string"}},
                    "tags": {"type": "array", "items": {"type": "string"}},
                    "code_refs": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "file_path": {"type": "string"},
                                "snippet": {"type": "string"},
                                "note": {"type": "string"},
                            },
                            "required": ["file_path", "snippet"],
                        },
                    },
                    "related_section_titles": {
                        "type": "array",
                        "items": {"type": "string"},
                    },
                },
                "required": ["kind", "title", "summary", "body", "tags"],
            },
        }
    },
}


def _build_prompt(files: list[dict[str, str]], focus_language: str | None) -> str:
    source_blocks = "\n\n".join(f"# {f['path']}\n```\n{f['content']}\n```" for f in files)
    focus_note = f"\n特に {focus_language} に関する項目を優先してください。" if focus_language else ""
    return (
        "以下のソースコードから、逆引きドキュメントを作成してください。"
        f"{focus_note}\n\n"
        f"{source_blocks}"
    )


def generate_mock_docs(files: list[dict[str, str]]) -> list[DocEntry]:
    """Vertex AI未接続時のフォールバック。

    実コードの内容は反映しないが、4種類の kind が揃った状態で画面を確認できるようにする。
    """
    sample_files = files or [{"path": "sample.py", "content": "def add(a, b):\n    return a + b"}]
    first = sample_files[0]
    file_name = first["path"].split("/")[-1]
    mock_note = "（これはVertex AI未接続時のモック応答です）"

    return [
        DocEntry(
            doc_id=str(uuid.uuid4()),
            kind="feature",
            title="サンプル機能",
            summary=f"このリポジトリの主要な処理をまとめた仮のエントリです。{mock_note}",
            body=(
                f"Vertex AI に接続されていないため、実際のコード解析は行われていません。\n\n"
                f"接続すると、ここには `{first['path']}` を含む実装の仕組みと設計意図が表示されます。"
            ),
            file_paths=[f["path"] for f in sample_files[:5]],
            symbols=["add"],
            tags=["サンプル", "機能", "sample", "feature", "モック", "mock"],
            code_refs=[
                CodeRef(
                    file_path=first["path"],
                    snippet=first["content"][:400],
                    note="対象リポジトリから実際に取得したソースの冒頭です。",
                )
            ],
        ),
        DocEntry(
            doc_id=str(uuid.uuid4()),
            kind="symbol",
            title="add()",
            summary=f"2つの引数を加算して返す関数です。{mock_note}",
            body="Vertex AI 接続時には、リポジトリ内の実際の関数・クラスがここに並びます。",
            file_paths=[first["path"]],
            symbols=["add"],
            tags=["add", "加算", "関数", "function", "サンプル"],
            code_refs=[
                CodeRef(
                    file_path="sample.py",
                    snippet="def add(a, b):\n    return a + b",
                    note="加算した結果をそのまま返しています。",
                )
            ],
        ),
        DocEntry(
            doc_id=str(uuid.uuid4()),
            kind="task",
            title="新しい機能を追加するには",
            summary=f"変更の起点になるファイルを見つける手順の仮エントリです。{mock_note}",
            body=(
                "Vertex AI 接続時には、実務でよくある作業（エンドポイント追加、"
                "設定項目の追加など）ごとに、どのファイルから読み始めればよいかが表示されます。"
            ),
            file_paths=[f["path"] for f in sample_files[:3]],
            tags=["追加", "変更", "手順", "add", "how to", "タスク", "task"],
        ),
        DocEntry(
            doc_id=str(uuid.uuid4()),
            kind="file",
            title=file_name,
            summary=f"`{first['path']}` の概要を示す仮エントリです。{mock_note}",
            body="Vertex AI 接続時には、各ソースファイルが何を担っているかの要約が表示されます。",
            file_paths=[first["path"]],
            tags=[file_name, "ファイル", "file", "概要"],
        ),
    ]


async def generate_docs(
    files: list[dict[str, str]], focus_language: str | None = None
) -> list[DocEntry]:
    if not settings.vertex_ai_configured:
        return generate_mock_docs(files)

    from vertexai.generative_models import GenerationConfig, GenerativeModel
    import vertexai

    vertexai.init(project=settings.gcp_project, location=settings.gcp_location)
    model = GenerativeModel("gemini-1.5-flash", system_instruction=SYSTEM_INSTRUCTION)

    response = await model.generate_content_async(
        _build_prompt(files, focus_language),
        generation_config=GenerationConfig(
            response_mime_type="application/json",
            response_schema=DOC_RESPONSE_SCHEMA,
            max_output_tokens=8192,
        ),
    )

    payload = json.loads(response.text)
    docs: list[DocEntry] = []
    for entry in payload.get("docs", []):
        code_refs = [CodeRef(**ref) for ref in entry.pop("code_refs", [])]
        docs.append(DocEntry(doc_id=str(uuid.uuid4()), code_refs=code_refs, **entry))
    return docs
