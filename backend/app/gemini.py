"""Gemini（Gemini Developer API）への接続を1箇所に集約する。

クイズ生成とドキュメント生成の両方から使う。SDKやモデルの差し替えが
ここだけで済むようにしてある。

背景: 以前はモデルIDが2ファイルにハードコードされており、
Gemini 1.5 の廃止時に両方を直す必要があった。同じことを繰り返さないよう、
モデルIDは環境変数 GEMINI_MODEL で差し替えられるようにしている。

接続方式について:
  `google-genai` SDK で ai.google.dev のGemini Developer APIを直接呼ぶ。
  認証はAPIキー1本。DBや認証など他の機能の設定とは完全に独立しており、
  それらが未設定でもGeminiだけは動く。
"""

import json
import logging
from typing import Any

from app.config import settings

logger = logging.getLogger(__name__)

_client = None


class GeminiError(Exception):
    """Geminiの呼び出しまたは応答の解析に失敗した。"""


class GeminiQuotaExceededError(GeminiError):
    """APIキーの利用枠を使い切った（429）。

    一時的な混雑（503）と違い、待っても短時間では回復しない。
    無料枠は「1日あたりのリクエスト数」で、1回の解析でクイズとドキュメントの
    2リクエストを消費する点に注意。
    """


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

    from google.genai import errors as genai_errors

    try:
        response = await _get_client().aio.models.generate_content(
            model=settings.gemini_model,
            contents=prompt,
            config=config,
        )
    except genai_errors.APIError as e:
        # モデルの混雑（503）や利用枠超過（429）はSDKがリトライし尽くした後にここへ来る。
        # 呼び出し側にGemini固有の例外を漏らさず、GeminiError系に変換する。
        # 429だけは「待っても直らない」ため、利用者への案内を変えられるよう別型にする。
        if getattr(e, "code", None) == 429:
            raise GeminiQuotaExceededError(f"Gemini quota exceeded: {e}") from e
        raise GeminiError(f"Gemini API call failed: {e}") from e

    # 出力途中で上限に達した場合、JSONは必ず壊れている。
    # json.loads の失敗として扱うより、原因の分かる形で先に弾く。
    # 現行モデルは思考モデルで、思考トークンも max_output_tokens を消費する点に注意。
    candidates = response.candidates or []
    if candidates and str(candidates[0].finish_reason) == "FinishReason.MAX_TOKENS":
        raise GeminiError(
            "Gemini hit the output token limit before completing the JSON"
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
