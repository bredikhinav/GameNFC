from tests.conftest import Api, uid


async def link_child(client, api, player_id) -> Api:
    link = await api.post(f"/players/{player_id}/device-link")
    assert link["qr_payload"] == f"fantikpay://link?code={link['code']}"
    child = Api(client)
    claimed = await child.post(
        "/device-link/claim", {"code": link["code"], "device_name": "Телефон Маши"}
    )
    child.token = claimed["token"]
    # One-time code.
    status, code = await Api(client).error("POST", "/device-link/claim", {"code": link["code"]})
    assert (status, code) == (400, "invalid_code")
    return child


async def test_child_home_and_transfers(client, api, family):
    s = family["space"]
    await api.req(
        "PATCH",
        f"/spaces/{s}",
        json={"daily_transfer_limit": 100, "transfer_approval_threshold": 50},
    )
    await api.tx(
        s, "credit", card_token=family["masha_card"], amount=340, comment="Уборка в комнате"
    )
    await api.req(
        "PUT", f"/players/{family['masha']}/goal", json={"title": "Самокат", "target_amount": 500}
    )
    child = await link_child(client, api, family["masha"])

    me = await child.get("/me")
    assert me["player"]["name"] == "Маша"
    assert me["balance"] == 340
    assert me["goal"] == {"title": "Самокат", "target_amount": 500}
    assert [p["name"] for p in me["peers"]] == ["Тимур"]
    assert me["recent"][0]["comment"] == "Уборка в комнате"
    assert me["active_game"] is None

    r = await child.post(
        "/me/transfers", {"id": uid(), "to_player_id": family["timur"], "amount": 20}
    )
    assert r == {
        "status": "done",
        "balance": 320,
        "transaction_id": r["transaction_id"],
        "request_id": None,
    }

    # Above the threshold: waits for a parent, money stays.
    req = await child.post(
        "/me/transfers", {"id": uid(), "to_card_token": family["timur_card"], "amount": 60}
    )
    assert req["status"] == "pending_approval" and req["balance"] == 320

    status, code = await child.error(
        "POST", "/me/transfers", {"id": uid(), "to_player_id": family["timur"], "amount": 30}
    )
    assert (status, code) == (409, "limit_exceeded")

    pending = await api.get(f"/spaces/{s}/transfer-requests")
    assert [p["amount"] for p in pending] == [60]
    approved = await api.post(f"/spaces/{s}/transfer-requests/{pending[0]['id']}/approve")
    assert approved["status"] == "approved"
    status, code = await api.error(
        "POST", f"/spaces/{s}/transfer-requests/{pending[0]['id']}/reject"
    )
    assert code == "request_already_decided"

    me = await child.get("/me")
    assert me["balance"] == 260
    assert me["transferred_today"] == 80

    # A child token is not an adult token and vice versa.
    status, _ = await child.error("GET", f"/spaces/{s}/players")
    assert status == 401
    status, _ = await api.error("GET", "/me")
    assert status == 401


async def test_child_sees_active_game_and_can_be_unlinked(client, api, family):
    s = family["space"]
    child = await link_child(client, api, family["masha"])
    sid = uid()
    await api.post(
        f"/spaces/{s}/sessions",
        {"id": sid, "name": "Настольная игра", "starting_capital": 1500},
        201,
    )
    for card in (family["masha_card"], family["timur_card"]):
        await api.post(f"/sessions/{sid}/join", {"card_token": card, "transaction_id": uid()})
    await api.post(f"/sessions/{sid}/status", {"status": "active"})
    await api.tx(s, "debit", session_id=sid, card_token=family["masha_card"], amount=200)

    game = (await child.get("/me"))["active_game"]
    assert (game["name"], game["balance"], game["place"], game["players"]) == (
        "Настольная игра",
        1300,
        2,
        2,
    )

    devices = await api.get(f"/players/{family['masha']}/devices")
    assert devices[0]["name"] == "Телефон Маши"
    await api.req("DELETE", f"/players/{family['masha']}/devices/{devices[0]['id']}", expect=204)
    status, _ = await child.error("GET", "/me")
    assert status == 401


async def test_child_cannot_overspend(client, api, family):
    child = await link_child(client, api, family["masha"])
    status, code = await child.error(
        "POST", "/me/transfers", {"id": uid(), "to_player_id": family["timur"], "amount": 1}
    )
    assert (status, code) == (409, "insufficient_funds")
    status, code = await child.error(
        "POST", "/me/transfers", {"id": uid(), "to_player_id": family["masha"], "amount": 1}
    )
    assert code == "same_player"
