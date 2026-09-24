from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="FP_", env_file=".env", extra="ignore")

    env: str = "dev"
    database_url: str = "postgresql+asyncpg://fantik:fantik@localhost:5432/fantikpay"
    redis_url: str = "redis://localhost:6379/0"

    jwt_secret: str = "dev-secret-change-me-dev-secret-change-me"
    access_token_ttl_seconds: int = 15 * 60
    refresh_token_ttl_days: int = 60

    # Base for NDEF links written to cards: {public_base_url}/c/{token}
    public_base_url: str = "https://fantikpay.ru"

    device_link_ttl_seconds: int = 10 * 60
    email_token_ttl_hours: int = 24

    login_rate_limit: int = 10  # attempts per window
    card_resolve_fail_limit: int = 20  # unknown-card taps per window per device
    rate_limit_window_seconds: int = 300

    sync_page_size: int = 2000


DEV_SECRET = Settings.model_fields["jwt_secret"].default


@lru_cache
def get_settings() -> Settings:
    settings = Settings()
    if settings.env == "prod" and (
        settings.jwt_secret == DEV_SECRET or len(settings.jwt_secret) < 32
    ):
        raise RuntimeError("FP_JWT_SECRET must be set to a random value of 32+ characters")
    return settings
