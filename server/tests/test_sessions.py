from tests.conftest import ts, uid


async def start_game(api, family, **kw):
    sid = uid()
    body = {
        "id": sid,
        "name": "Настольная игра",
        "money_mode": "reset",
        "starting_capital": 1500,
        "created_at": ts(),
        **kw,
    }
    await api.post(f"/spaces/{family['space']}/sessions", body, 201)
    for card in (family["masha_card"], family["timur_card"]):
        await api.post(f"/sessions/{sid}/join", {"card_token": card, "transaction_id": uid()})
    await api.post(f"/sessions/{sid}/status", {"status": "active"})
    return sid


async def test_reset_game_keeps_savings(api, family):
    s = family["space"]
    await api.tx(s, "credit", card_token=family["masha_card"], amount=340)
    sid = await start_game(api, family)

    game = await api.get(f"/sessions/{sid}")
    assert [(x["name"], x["balance"]) for x in game["standings"]] == [
        ("Маша", 1500),
        ("Тимур", 1500),
    ]

    await api.tx(
        s,
        "debit",
        session_id=sid,
        card_token=family["masha_card"],
        amount=200,
        comment="Покупка улицы",
    )
    await api.tx(
        s,
        "transfer",
        session_id=sid,
        card_token=family["masha_card"],
        to_card_token=family["timur_card"],
        amount=100,
    )
    await api.tx(s, "credit", session_id=sid, card_token=family["timur_card"], amount=200)

    # Joining twice is a no-op.
    again = await api.post(
        f"/sessions/{sid}/join", {"card_token": family["masha_card"], "transaction_id": uid()}
    )
    assert again["already_joined"] is True

    # Pause blocks operations.
    await api.post(f"/sessions/{sid}/status", {"status": "paused"})
    status, code = await api.error(
        "POST",
        "/transactions",
        {
            "id": uid(),
            "type": "credit",
            "space_id": s,
            "session_id": sid,
            "card_token": family["masha_card"],
            "amount": 1,
        },
    )
    assert (status, code) == (409, "session_not_active")
    await api.post(f"/sessions/{sid}/status", {"status": "active"})

    prize_tx = uid()
    result = await api.post(
        f"/sessions/{sid}/finish",
        {"prizes": [{"player_id": family["timur"], "amount": 20, "transaction_id": prize_tx}]},
    )
    assert result["status"] == "finished"
    assert [(x["place"], x["name"], x["balance"], x["net"]) for x in result["standings"]] == [
        (1, "Тимур", 1800, 300),
        (2, "Маша", 1200, -300),
    ]
    players = {p["name"]: p["balance"] for p in await api.get(f"/spaces/{s}/players")}
    assert players == {"Маша": 340, "Тимур": 20}

    # Finished game rejects operations; finishing again is idempotent.
    status, code = await api.error(
        "POST",
        "/transactions",
        {
            "id": uid(),
            "type": "credit",
            "space_id": s,
            "session_id": sid,
            "card_token": family["masha_card"],
            "amount": 1,
        },
    )
    assert code == "session_not_active"
    await api.post(
        f"/sessions/{sid}/finish",
        {"prizes": [{"player_id": family["timur"], "amount": 20, "transaction_id": prize_tx}]},
    )
    assert {p["name"]: p["balance"] for p in await api.get(f"/spaces/{s}/players")}["Тимур"] == 20

    history = await api.get(f"/players/{family['masha']}/history?session_id={sid}")
    assert [h["signed_amount"] for h in history] == [-100, -200, 1500]


async def test_card_not_in_session(api, family):
    s = family["space"]
    sid = uid()
    await api.post(
        f"/spaces/{s}/sessions", {"id": sid, "name": "Игра", "starting_capital": 100}, 201
    )
    await api.post(
        f"/sessions/{sid}/join", {"card_token": family["masha_card"], "transaction_id": uid()}
    )
    await api.post(f"/sessions/{sid}/status", {"status": "active"})
    status, code = await api.error(
        "POST",
        "/transactions",
        {
            "id": uid(),
            "type": "debit",
            "space_id": s,
            "session_id": sid,
            "card_token": family["timur_card"],
            "amount": 1,
        },
    )
    assert (status, code) == (409, "card_not_in_session")
    r = await api.post(
        "/cards/resolve", {"space_id": s, "token": family["timur_card"], "session_id": sid}
    )
    assert r["in_session"] is False


async def test_persistent_money_game(api, family):
    s = family["space"]
    await api.tx(s, "credit", card_token=family["masha_card"], amount=100)
    sid = await start_game(api, family, money_mode="persistent", starting_capital=999)
    await api.tx(s, "debit", session_id=sid, card_token=family["masha_card"], amount=30)
    result = await api.post(f"/sessions/{sid}/finish", {})
    assert [(x["name"], x["net"]) for x in result["standings"]] == [("Тимур", 0), ("Маша", -30)]
    players = {p["name"]: p["balance"] for p in await api.get(f"/spaces/{s}/players")}
    assert players == {"Маша": 70, "Тимур": 0}


async def test_invalid_transition(api, family):
    sid = uid()
    await api.post(f"/spaces/{family['space']}/sessions", {"id": sid, "name": "Игра"}, 201)
    status, code = await api.error("POST", f"/sessions/{sid}/status", {"status": "paused"})
    assert (status, code) == (409, "invalid_status_transition")
