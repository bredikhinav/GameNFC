from app.services import jobs
from tests.conftest import Api, ts, uid


def tx_op(space, type_, **kw):
    return {
        "kind": "transaction",
        "transaction": {"id": uid(), "type": type_, "space_id": space, "created_at": ts(), **kw},
    }


async def test_offline_game_then_sync(api, family, db):
    s = family["space"]
    device = uid()
    sid = uid()
    ops = [
        {
            "kind": "session.create",
            "session": {
                "id": sid,
                "name": "Без интернета",
                "starting_capital": 1000,
                "created_at": ts(),
                "device_id": device,
            },
        },
        {
            "kind": "session.join",
            "session_id": sid,
            "join": {
                "card_token": family["masha_card"],
                "transaction_id": uid(),
                "joined_at": ts(),
            },
        },
        {
            "kind": "session.join",
            "session_id": sid,
            "join": {
                "card_token": family["timur_card"],
                "transaction_id": uid(),
                "joined_at": ts(),
            },
        },
        {"kind": "session.status", "session_id": sid, "status": {"status": "active"}},
        tx_op(s, "debit", session_id=sid, card_token=family["masha_card"], amount=300),
        tx_op(s, "debit", session_id=sid, card_token="noSuchCard0000", amount=1),
        {"kind": "session.finish", "session_id": sid, "finish": {}},
    ]
    r = await api.post("/sync", {"space_id": s, "device_id": device, "cursor": 0, "ops": ops})
    assert [x["ok"] for x in r["results"]] == [True, True, True, True, True, False, True]
    assert r["results"][5]["error"] == "card_not_found"
    assert r["has_more"] is False
    changes = r["changes"]
    assert changes["space"]["name"] == "Моя семья"
    assert {p["name"] for p in changes["players"]} == {"Маша", "Тимур"}
    assert len(changes["cards"]) == 2
    assert changes["sessions"][0]["status"] == "finished"
    assert len(changes["participants"]) == 2
    assert len(changes["transactions"]) == 3
    assert changes["templates"][0]["name"] == "Настольная экономическая игра"

    # Retrying the whole batch (lost response) changes nothing.
    again = await api.post(
        "/sync", {"space_id": s, "device_id": device, "cursor": r["cursor"], "ops": ops[:5]}
    )
    assert all(x["ok"] for x in again["results"])
    assert [x["duplicate"] for x in again["results"]][1:] == [True, True, False, True]
    assert again["changes"]["transactions"] == []
    assert again["cursor"] >= r["cursor"]
    assert await jobs.reconcile(db) == 0

    devices = await api.get(f"/spaces/{s}/devices")
    assert devices[0]["id"] == device


async def test_second_terminal_pulls_changes(client, api, family):
    s = family["space"]
    first = await api.post("/sync", {"space_id": s, "device_id": uid(), "cursor": 0})
    cursor = first["cursor"]
    await api.tx(s, "credit", card_token=family["masha_card"], amount=50)
    r = await api.post("/sync", {"space_id": s, "device_id": uid(), "cursor": cursor})
    assert len(r["changes"]["transactions"]) == 1
    assert [w["balance"] for w in r["changes"]["wallets"]] and any(
        w["player_id"] == family["masha"] and w["balance"] == 50 for w in r["changes"]["wallets"]
    )
    assert r["changes"]["players"] == []
    assert r["changes"]["space"] is None


async def test_offline_overdraft_is_accepted_and_flagged(api, family):
    s = family["space"]
    await api.tx(s, "credit", card_token=family["masha_card"], amount=40)
    # Two terminals spent the same coins offline.
    ops = [tx_op(s, "debit", card_token=family["masha_card"], amount=30) for _ in range(2)]
    r = await api.post("/sync", {"space_id": s, "device_id": uid(), "cursor": 0, "ops": ops})
    assert all(x["ok"] for x in r["results"])
    masha = next(p for p in await api.get(f"/spaces/{s}/players") if p["name"] == "Маша")
    assert masha["balance"] == -20 and masha["flagged"] is True
    summary = await api.get(f"/spaces/{s}/summary")
    assert summary["flagged_wallets"] == 1
    await api.post(f"/spaces/{s}/wallets/{masha['wallet_id']}/resolve-flag", expect=204)
    assert (await api.get(f"/spaces/{s}/summary"))["flagged_wallets"] == 0


async def test_offline_op_before_block_stands(api, family):
    from datetime import UTC, datetime, timedelta

    s = family["space"]
    card = next(p for p in await api.get(f"/spaces/{s}/players") if p["name"] == "Маша")["cards"][0]
    before = (datetime.now(UTC) - timedelta(minutes=5)).isoformat()
    await api.post(f"/cards/{card['id']}/block")
    ops = [
        {
            "kind": "transaction",
            "transaction": {
                "id": uid(),
                "type": "credit",
                "space_id": s,
                "card_token": family["masha_card"],
                "amount": 5,
                "created_at": before,
            },
        },
        tx_op(s, "credit", card_token=family["masha_card"], amount=5),
    ]
    r = await api.post("/sync", {"space_id": s, "device_id": uid(), "ops": ops})
    assert [x["ok"] for x in r["results"]] == [True, False]
    assert r["results"][1]["error"] == "card_blocked"


async def test_sync_pagination(api, family, monkeypatch):
    from app.config import get_settings

    s = family["space"]
    for _ in range(5):
        await api.tx(s, "credit", card_token=family["masha_card"], amount=1)
    monkeypatch.setattr(get_settings(), "sync_page_size", 3)
    cursor, seen, pages = 0, 0, 0
    while True:
        r = await api.post("/sync", {"space_id": s, "device_id": uid(), "cursor": cursor})
        seen += len(r["changes"]["transactions"])
        cursor, pages = r["cursor"], pages + 1
        if not r["has_more"]:
            break
    assert seen == 5 and pages > 1


async def test_sync_requires_membership(client, family):
    other = Api(client)
    await other.register()
    status, code = await other.error(
        "POST", "/sync", {"space_id": family["space"], "device_id": uid()}
    )
    assert status == 404
