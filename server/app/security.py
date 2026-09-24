import base64
import hashlib
import hmac
import secrets
import string
from datetime import UTC, datetime, timedelta
from uuid import UUID

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import VerificationError

from app.config import get_settings

_ph = PasswordHasher()
_ALPHABET = string.ascii_letters + string.digits
PLAYER_TOKEN_PREFIX = "fpd_"
PIN_ITERATIONS = 120_000


def now() -> datetime:
    return datetime.now(UTC)


def hash_password(password: str) -> str:
    return _ph.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        return _ph.verify(password_hash, password)
    except VerificationError:
        return False


def sha256(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def random_token(length: int = 32) -> str:
    return "".join(secrets.choice(_ALPHABET) for _ in range(length))


def card_token() -> str:
    # 16 base62 chars ~ 95 bits: short enough for NTAG213, impossible to guess.
    return random_token(16)


def short_code(length: int = 8) -> str:
    # No ambiguous characters: it may be typed by hand if the camera fails.
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def create_access_token(user_id: UUID) -> str:
    s = get_settings()
    issued = now()
    payload = {
        "sub": str(user_id),
        "typ": "access",
        "iat": issued,
        "exp": issued + timedelta(seconds=s.access_token_ttl_seconds),
    }
    return jwt.encode(payload, s.jwt_secret, algorithm="HS256")


def decode_access_token(token: str) -> UUID | None:
    try:
        payload = jwt.decode(token, get_settings().jwt_secret, algorithms=["HS256"])
    except jwt.PyJWTError:
        return None
    if payload.get("typ") != "access":
        return None
    try:
        return UUID(payload["sub"])
    except (KeyError, ValueError):
        return None


def hash_pin(pin: str, salt: bytes | None = None) -> tuple[str, str, int]:
    """PBKDF2 so that the app can verify the PIN offline with the same parameters."""
    salt = salt or secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", pin.encode(), salt, PIN_ITERATIONS)
    return base64.b64encode(salt).decode(), base64.b64encode(digest).decode(), PIN_ITERATIONS


def verify_pin(pin: str, salt_b64: str, hash_b64: str, iterations: int) -> bool:
    digest = hashlib.pbkdf2_hmac("sha256", pin.encode(), base64.b64decode(salt_b64), iterations)
    return hmac.compare_digest(base64.b64encode(digest).decode(), hash_b64)
