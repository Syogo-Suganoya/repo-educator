"""Gemini（Gemini Developer API）への接続を1箇所に集約する。

クイズ生成とドキュメント生成の両方から使う。SDKやモデルの差し替えが
ここだけで済むようにしてある。

背景: 以前はモデルIDが2ファイルにハードコードされており、
Gemini 1.5 の廃止時に両方を直す必要があった。同じことを繰り返さないよう、
モデルIDは環境変数 GEMINI_MODEL で差し替えられるようにしている。

接続方式について:
  GCPプロジェクト・IAMを経由する Vertex AI ではなく、単体のAPIキーで
  ai.google.dev のGemini Developer APIを直接呼ぶ。Firestore等の他機能とは
  完全に独立しており、GCPプロジェクトの設定と関係なくGeminiだけを使える。

SDKについて:
  旧 `vertexai.generative_models`（google-cloud-aiplatform）は
  2025-06-24に非推奨化され2026-06-24に削除された。
  現在は `google-genai` が唯一のサポート対象で、新しいGeminiモデルは
  こちらからしか使えない。
"""

import json
import logging
from typing import Any

from app.config import settings

logger = logging.getLogger(__name__)

_client = None


class GeminiError(Exception):
    """Geminiの呼び出しまたは応答の解析に失敗した。"""


def _get_client():
    """Gemini Developer API 向けのクライアントを遅延生成する（プロセスで1つ）。

    認証はAPIキー1本。GCPのサービスアカウントやADCは関与しない。
    """
    global _client
    if _client is None:
        from google import genai

        _client = genai.Client(api_key=settings.gemini_api_key)
    return _client


async def generate_json(
    *,
    system_instruction: str,
    prompt: str,
    response_schema: dict[str, Any],
    max_output_tokens: int | None = None,
) -> dict[str, Any]:
    """Structured Outputs でJSONを生成し、辞書として返す。

    同期版ではなく `client.aio` を使う。クイズ生成とドキュメント生成を
    asyncio.gather で並行実行するため、イベントループを塞いではいけない。
    """
    from google.genai import types

    config = types.GenerateContentConfig(
        system_instruction=system_instruction,
        response_mime_type="application/json",
        response_schema=response_schema,
    )
    if max_output_tokens is not None:
        config.max_output_tokens = max_output_tokens

    response = await _get_client().aio.models.generate_content(
        model=settings.gemini_model,
        contents=prompt,
        config=config,
    )

    text = response.text
    if not text:
        raise GeminiError("Gemini returned an empty response")

    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        # 出力トークン上限に達してJSONが途中で切れた場合にここへ来る。
        # 応答本文はプライベートリポジトリのコードを含みうるのでログに出さない。
        logger.warning(
            "Gemini returned malformed JSON (%d chars); the output may have been truncated",
            len(text),
        )
        raise GeminiError("Gemini returned malformed JSON") from e
