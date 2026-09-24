from redis.asyncio import Redis

from app.config import get_settings
from app.errors import AppError

_redis: Redis | None = None


def get_redis() -> Redis:
    global _redis
    if _redis is None:
        _redis = Redis.from_url(get_settings().redis_url, decode_responses=True)
    return _redis


async def hit(key: str, limit: int, window: int | None = None) -> None:
    """Fixed-window rate limit. Raises `rate_limited` once `limit` is exceeded."""
    window = window or get_settings().rate_limit_window_seconds
    r = get_redis()
    full_key = f"rl:{key}"
    count = await r.incr(full_key)
    if count == 1:
        await r.expire(full_key, window)
    if count > limit:
        ttl = await r.ttl(full_key)
        raise AppError("rate_limited", 429, retry_after=max(ttl, 1))


async def is_limited(key: str, limit: int) -> bool:
    value = await get_redis().get(f"rl:{key}")
    return value is not None and int(value) >= limit


async def reset(key: str) -> None:
    await get_redis().delete(f"rl:{key}")
