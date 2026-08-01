"""Cloud KMS による GitHub ユーザートークンの暗号化・復号。

保存するのは GitHub の「ユーザートークン」のみ。リポジトリ本体へのアクセスに使う
installation access token は都度発行の短命トークンなので保存しない（github_app.py 参照）。

KMS_KEY_NAME が未設定のローカル開発では、暗号化できないトークンを平文で保存する
くらいなら保存しない方がよいため、encrypt は None を返す。
"""

import logging

from app.config import settings

logger = logging.getLogger(__name__)

_client = None


def kms_configured() -> bool:
    return bool(settings.kms_key_name)


def _get_client():
    global _client
    if _client is None:
        from google.cloud import kms

        _client = kms.KeyManagementServiceClient()
    return _client


def encrypt(plaintext: str) -> bytes | None:
    """暗号文を返す。KMS未設定なら None（＝保存しない）。"""
    if not plaintext or not kms_configured():
        return None
    try:
        response = _get_client().encrypt(
            request={"name": settings.kms_key_name, "plaintext": plaintext.encode("utf-8")}
        )
        return response.ciphertext
    except Exception as e:
        logger.warning("KMS encrypt failed: %s", type(e).__name__)
        return None


def decrypt(ciphertext: bytes | None) -> str | None:
    if not ciphertext or not kms_configured():
        return None
    try:
        response = _get_client().decrypt(
            request={"name": settings.kms_key_name, "ciphertext": bytes(ciphertext)}
        )
        return response.plaintext.decode("utf-8")
    except Exception as e:
        logger.warning("KMS decrypt failed: %s", type(e).__name__)
        return None
