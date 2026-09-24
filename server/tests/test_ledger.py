import asyncio

from app.services import jobs
from tests.conftest import Api, ts, uid


async def balances(api, space_id):
    return {p["name"]: p["balance"] for p in await api.get(f"/spaces/{space_id}/players")}


async def test_credit_debit_transfer(api, family):
    s = family["space"]
    r = await api.tx(s, "credit", card_token=family["masha_card"], amount=500, comment="Уборка")
    assert r["player"]["name"] == "Маша"
    assert r["balances"][0]["balance"] == 500

    await api.tx(s, "debit", card_token=family["masha_card"], amount=120)
    status, code = await api.error(
        "POST",
        "/transactions",
        {
            "id": uid(),
            "type": "debit",
            "space_id": s,
            "card_token": family["masha_card"],
            "amount": 1000,
        },
    )
    assert (status, code) == (409, "insufficient_funds")

    r = await api.tx(
        s,
        "transfer",
        card_token=family["masha_card"],
        to_card_token=family["timur_card"],
        amount=80,
    )
    assert r["to_player"]["name"] == "Тимур"
    assert await balances(api, s) == {"Маша": 300, "Тимур": 80}

    # Card without NDEF resolves by UID.
    await api.tx(s, "debit", card_uid="04a1b2c3d4e5f6", amount=10)
    assert (await balances(api, s))["Маша"] == 290


async def test_resolve_tap(api, family):
    await api.tx(family["space"], "credit", card_token=family["masha_card"], amount=42)
    r = await api.post(
        "/cards/resolve", {"space_id": family["space"], "token": family["masha_card"]}
    )
    assert r["player"]["name"] == "Маша"
    assert r["wallets"] == [
        {
            "wallet_id": r["player"]["wallet_id"],
            "kind": "persistent",
            "player_id": family["masha"],
            "session_id": None,
            "balance": 42,
            "flagged": False,
        }
    ]
    status, code = await api.error(
        "POST", "/cards/resolve", {"space_id": family["space"], "token": "unknownToken1"}
    )
    assert (status, code) == (404, "card_not_found")


async def test_idempotent_retry(api, family):
    body = {
        "id": uid(),
        "type": "credit",
        "space_id": family["space"],
        "card_token": family["masha_card"],
        "amount": 100,
        "created_at": ts(),
    }
    first = await api.post("/transactions", body)
    second = await api.post("/transactions", body)
    assert first["transaction"]["id"] == second["transaction"]["id"]
    assert second["duplicate"] is True
    assert (await balances(api, family["space"]))["Маша"] == 100
    status, code = await api.error("POST", "/transactions", {**body, "type": "debit"})
    assert (status, code) == (409, "id_conflict")


async def test_reversal(api, family):
    s = family["space"]
    r = await api.tx(s, "credit", card_token=family["masha_card"], amount=200)
    original = r["transaction"]["id"]
    rev = await api.tx(s, "reversal", reverses_id=original)
    assert rev["player"]["name"] == "Маша"
    assert (await balances(api, s))["Маша"] == 0
    status, code = await api.error(
        "POST",
        "/transactions",
        {"id": uid(), "type": "reversal", "space_id": s, "reverses_id": original},
    )
    assert code == "already_reversed"
    history = await api.get(f"/players/{family['masha']}/history")
    assert [h["type"] for h in history] == ["reversal", "credit"]
    assert history[1]["reversed"] is True


async def test_concurrent_debits_never_overdraw(client, api, family, db):
    s = family["space"]
    await api.tx(s, "credit", card_token=family["masha_card"], amount=1000)

    async def debit():
        r = await client.post(
            "/api/v1/transactions",
            headers=api.headers,
            json={
                "id": uid(),
                "type": "debit",
                "space_id": s,
                "card_token": family["masha_card"],
                "amount": 100,
            },
        )
        return r.status_code

    codes = await asyncio.gather(*[debit() for _ in range(25)])
    assert codes.count(200) == 10
    assert codes.count(409) == 15
    assert (await balances(api, s))["Маша"] == 0
    assert await jobs.reconcile(db) == 0


async def test_negative_allowed_by_settings(api, family):
    s = family["space"]
    await api.req("PATCH", f"/spaces/{s}", json={"allow_negative": True})
    await api.tx(s, "debit", card_token=family["masha_card"], amount=30)
    assert (await balances(api, s))["Маша"] == -30


async def test_permissions(client, api, family):
    s = family["space"]
    operator = Api(client)
    await operator.register("operator@example.com")
    stranger = Api(client)
    await stranger.register()

    status, code = await stranger.error("GET", f"/spaces/{s}/players")
    assert (status, code) == (404, "space_not_found")

    await api.post(
        f"/spaces/{s}/members", {"email": "operator@example.com", "role": "operator"}, 201
    )
    await operator.tx(s, "credit", card_token=family["masha_card"], amount=5)
    status, code = await operator.error(
        "POST", f"/spaces/{s}/players", {"name": "X", "consent": True}
    )
    assert (status, code) == (403, "forbidden")
    status, _ = await operator.error("PATCH", f"/spaces/{s}", {"daily_transfer_limit": 1})
    assert status == 403


async def test_player_requires_consent(api):
    await api.register()
    space = await api.space()
    status, code = await api.error(
        "POST", f"/spaces/{space['id']}/players", {"name": "Маша", "consent": False}
    )
    assert (status, code) == (422, "validation_error")


async def test_delete_player_anonymizes(api, family):
    s = family["space"]
    await api.tx(s, "credit", card_token=family["masha_card"], amount=10)
    await api.req("DELETE", f"/players/{family['masha']}", expect=204)
    names = [p["name"] for p in await api.get(f"/spaces/{s}/players")]
    assert names == ["Тимур"]
    status, code = await api.error(
        "POST", "/cards/resolve", {"space_id": s, "token": family["masha_card"]}
    )
    assert code in ("card_not_found", "card_unlinked")


async def test_allowances_run_once_per_day(api, family, db):
    from datetime import UTC, datetime, timedelta

    s = family["space"]
    now = datetime.now(UTC)
    weekday = now.astimezone().weekday()
    # Compute weekday in the space time zone the same way the job does.
    from zoneinfo import ZoneInfo

    weekday = now.astimezone(ZoneInfo("Europe/Moscow")).weekday()
    await api.post(
        f"/spaces/{s}/allowances", {"amount": 30, "comment": "Карманные", "weekday": weekday}, 201
    )
    await api.post(
        f"/spaces/{s}/allowances",
        {
            "amount": 5,
            "comment": "Не сегодня",
            "weekday": (weekday + 1) % 7,
            "player_id": family["masha"],
        },
        201,
    )
    assert await jobs.run_allowances(db, now) == 2
    assert await jobs.run_allowances(db, now + timedelta(minutes=5)) == 0
    assert await balances(api, s) == {"Маша": 30, "Тимур": 30}
    assert await jobs.reconcile(db) == 0
