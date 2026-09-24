import os
import uuid
from datetime import UTC, datetime

os.environ.setdefault(
    "FP_DATABASE_URL", "postgresql+asyncpg://fantik:fantik@localhost:5432/fantikpay_test"
)
os.environ.setdefault("FP_REDIS_URL", "redis://localhost:6379/15")
os.environ["FP_ENV"] = "test"

import pytest  # noqa: E402
from alembic import command  # noqa: E402
from alembic.config import Config  # noqa: E402
from httpx import ASGITransport, AsyncClient  # noqa: E402
from sqlalchemy import text  # noqa: E402

from app.db import SessionLocal, engine  # noqa: E402
from app.main import app  # noqa: E402
from app.redis import get_redis  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEEP = {"alembic_version", "game_templates"}


@pytest.fixture(scope="session", autouse=True)
async def schema():
    async with engine.begin() as conn:
        await conn.execute(text("DROP SCHEMA public CASCADE"))
        await conn.execute(text("CREATE SCHEMA public"))
    cfg = Config(os.path.join(HERE, "alembic.ini"))
    cfg.set_main_option("script_location", os.path.join(HERE, "migrations"))
    # env.py runs its own event loop; alembic must run outside ours.
    import asyncio

    await asyncio.to_thread(command.upgrade, cfg, "head")
    yield
    await engine.dispose()


@pytest.fixture(autouse=True)
async def clean(schema):
    yield
    async with engine.begin() as conn:
        tables = (
            await conn.execute(text("SELECT tablename FROM pg_tables WHERE schemaname = 'public'"))
        ).scalars()
        names = [t for t in tables if t not in KEEP]
        # Built-in templates are seed data; CASCADE from spaces would wipe them too.
        await conn.execute(
            text("CREATE TEMP TABLE builtin AS SELECT * FROM game_templates WHERE space_id IS NULL")
        )
        await conn.execute(text(f"TRUNCATE {', '.join(names)}, game_templates CASCADE"))
        await conn.execute(text("INSERT INTO game_templates SELECT * FROM builtin"))
        await conn.execute(text("DROP TABLE builtin"))
    await get_redis().flushdb()


@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


@pytest.fixture
async def db():
    async with SessionLocal() as session:
        yield session


def uid() -> str:
    return str(uuid.uuid4())


def ts() -> str:
    return datetime.now(UTC).isoformat()


class Api:
    """Thin helper over the HTTP API for readable tests."""

    def __init__(self, client: AsyncClient, token: str | None = None):
        self.client = client
        self.token = token

    @property
    def headers(self) -> dict:
        return {"Authorization": f"Bearer {self.token}"} if self.token else {}

    async def req(self, method: str, path: str, expect: int | None = 200, **kw):
        r = await self.client.request(method, "/api/v1" + path, headers=self.headers, **kw)
        if expect is not None:
            assert r.status_code == expect, f"{method} {path}: {r.status_code} {r.text}"
        return r.json() if r.content else None

    async def get(self, path, expect=200, **kw):
        return await self.req("GET", path, expect, **kw)

    async def post(self, path, json=None, expect=200, **kw):
        return await self.req("POST", path, expect, json=json, **kw)

    async def error(self, method: str, path: str, json=None) -> tuple[int, str]:
        r = await self.client.request(method, "/api/v1" + path, headers=self.headers, json=json)
        return r.status_code, r.json()["error"]["code"]

    # --- scenario helpers ---

    async def register(self, email: str | None = None, password: str = "password123"):
        email = email or f"{uuid.uuid4().hex[:10]}@example.com"
        tokens = await self.post(
            "/auth/register", {"email": email, "password": password, "name": "Мама"}, 201
        )
        self.token = tokens["access_token"]
        self.email = email
        return tokens

    async def space(self, **kw):
        return await self.post("/spaces", {"name": "Моя семья", **kw}, 201)

    async def player(self, space_id: str, name: str, **kw):
        return await self.post(
            f"/spaces/{space_id}/players", {"name": name, "consent": True, **kw}, 201
        )

    async def card(self, player_id: str, uid_hex: str | None = None) -> str:
        prepared = await self.post("/cards/prepare")
        body = {"token": prepared["token"], "player_id": player_id}
        if uid_hex:
            body["uid"] = uid_hex
        await self.post("/cards/activate", body)
        return prepared["token"]

    async def tx(self, space_id: str, type_: str, expect=200, **kw):
        body = {"id": uid(), "type": type_, "space_id": space_id, "created_at": ts(), **kw}
        return await self.post("/transactions", body, expect)


@pytest.fixture
def api(client) -> Api:
    return Api(client)


@pytest.fixture
async def family(api: Api):
    """A parent with a family space, two children and a card each."""
    await api.register()
    space = await api.space()
    masha = await api.player(space["id"], "Маша")
    timur = await api.player(space["id"], "Тимур")
    return {
        "space": space["id"],
        "masha": masha["id"],
        "timur": timur["id"],
        "masha_card": await api.card(masha["id"], "04A1B2C3D4E5F6"),
        "timur_card": await api.card(timur["id"]),
    }
