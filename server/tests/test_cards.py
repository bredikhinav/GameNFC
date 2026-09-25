import csv

from app import cli
from tests.conftest import uid


async def test_block_unlink_relink(api, family):
    s = family["space"]
    players = await api.get(f"/spaces/{s}/players")
    card = players[0]["cards"][0]
    blocked = await api.post(f"/cards/{card['id']}/block")
    assert blocked["status"] == "blocked"
    status, code = await api.error(
        "POST",
        "/transactions",
        {
            "id": uid(),
            "type": "credit",
            "space_id": s,
            "card_token": family["masha_card"],
            "amount": 1,
        },
    )
    assert (status, code) == (409, "card_blocked")

    await api.post(f"/cards/{card['id']}/unlink")
    status, code = await api.error(
        "POST", "/cards/resolve", {"space_id": s, "token": family["masha_card"]}
    )
    assert code == "card_unlinked"

    # The card is handed to Тимур; Маша's history stays with Маша.
    await api.post("/cards/activate", {"token": family["masha_card"], "player_id": family["timur"]})
    r = await api.post("/cards/resolve", {"space_id": s, "token": family["masha_card"]})
    assert r["player"]["name"] == "Тимур"


async def test_activate_errors(api, family):
    status, code = await api.error(
        "POST", "/cards/activate", {"token": family["masha_card"], "player_id": family["timur"]}
    )
    assert (status, code) == (409, "card_already_linked")
    status, code = await api.error(
        "POST", "/cards/activate", {"token": "doesNotExist01", "player_id": family["timur"]}
    )
    assert code == "card_not_found"
    # NDEF copied onto another chip: the UID does not match.
    prepared = await api.post("/cards/prepare")
    await api.post(
        "/cards/activate",
        {"token": prepared["token"], "player_id": family["timur"], "uid": "04AAAAAAAAAAAA"},
    )
    await api.post(
        f"/cards/{(await api.post('/cards/resolve', {'space_id': family['space'], 'token': prepared['token']}))['card']['id']}/unlink"
    )
    status, code = await api.error(
        "POST",
        "/cards/activate",
        {"token": prepared["token"], "player_id": family["timur"], "uid": "04BBBBBBBBBBBB"},
    )
    assert code == "card_uid_mismatch"
    assert prepared["url"] == f"https://fantikpay.ru/c/{prepared['token']}"


async def test_warehouse_batch_requires_activation_code(api, family, tmp_path):
    out = tmp_path / "batch.csv"
    await cli.generate_batch("Партия 1", 3, "ntag215", str(out))
    rows = list(csv.DictReader(out.open()))
    assert len(rows) == 3 and rows[0]["ndef_url"].endswith(rows[0]["token"])

    token, code = rows[0]["token"], rows[0]["activation_code"]
    status, err = await api.error(
        "POST", "/cards/activate", {"token": token, "player_id": family["masha"]}
    )
    assert (status, err) == (403, "invalid_activation_code")
    await api.post(
        "/cards/activate",
        {"token": token, "player_id": family["masha"], "activation_code": code.lower()},
    )

    imported = tmp_path / "factory.csv"
    imported.write_text("token,uid,activation_code\nfactoryTok00001,04CCCCCCCCCCCC,ABCD2345\n")
    await cli.import_batch("Завод", "ntag213", str(imported))
    await api.post(
        "/cards/activate",
        {
            "token": "factoryTok00001",
            "player_id": family["timur"],
            "activation_code": "ABCD2345",
            "uid": "04cccccccccccc",
        },
    )


async def test_public_card_page(client, family):
    r = await client.get(f"/c/{family['masha_card']}")
    assert r.status_code == 200
    assert "ФантикПэй" in r.text and "Маша" not in r.text


async def test_seed_demo_is_usable(api):
    from tests.conftest import uid

    await cli.seed_demo()
    await cli.seed_demo()  # idempotent
    login = await api.post("/auth/login", {"email": cli.DEMO_EMAIL, "password": cli.DEMO_PASSWORD})
    api.token = login["access_token"]
    space = (await api.get("/spaces"))[0]
    players = {p["name"]: p["balance"] for p in await api.get(f"/spaces/{space['id']}/players")}
    assert players == {"Маша": 340, "Тимур": 125, "Соня": 60}
    await api.post(
        "/transactions",
        {
            "id": uid(),
            "type": "debit",
            "space_id": space["id"],
            "card_token": "DEMOMASHA01",
            "amount": 40,
        },
    )
