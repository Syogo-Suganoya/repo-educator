"""GitHub Personal Access Token の暗号化・復号。

ユーザーが自分で発行し、設定画面から入力した PAT を保存する用途のみに使う。
環境変数としてサーバに焼き込むトークンは扱わない（1ユーザー1トークンとして
DBに保存し、ログアウト後も残る）。

暗号化は `cryptography.fernet` による対称鍵方式。鍵は環境変数 ENCRYPTION_KEY で渡す。

ENCRYPTION_KEY が未設定のローカル開発では、暗号化できないトークンを平文で保存する
くらいなら保存しない方がよいため、encrypt は None を返す。
"""

import logging

from app.config import settings

logger = logging.getLogger(__name__)

_fernet = None


def encryption_configured() -> bool:
    return bool(settings.encryption_key)


def _get_fernet():
    global _fernet
    if _fernet is None:
        from cryptography.fernet import Fernet

        _fernet = Fernet(settings.encryption_key.encode("utf-8"))
    return _fernet


def encrypt(plaintext: str) -> bytes | None:
    """暗号文を返す。暗号化鍵が未設定なら None（＝保存しない）。"""
    if not plaintext or not encryption_configured():
        return None
    try:
        return _get_fernet().encrypt(plaintext.encode("utf-8"))
    except Exception as e:
        logger.warning("Encryption failed: %s", type(e).__name__)
        return None


def decrypt(ciphertext: bytes | None) -> str | None:
    if not ciphertext or not encryption_configured():
        return None
    try:
        return _get_fernet().decrypt(bytes(ciphertext)).decode("utf-8")
    except Exception as e:
        logger.warning("Decryption failed: %s", type(e).__name__)
        return None
