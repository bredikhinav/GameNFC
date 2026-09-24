async def test_health(client):
    r = await client.get("/health")
    assert r.json() == {"status": "ok"}


async def test_family_fixture(api, family):
    players = await api.get(f"/spaces/{family['space']}/players")
    assert [p["name"] for p in players] == ["Маша", "Тимур"]
    assert all(p["balance"] == 0 and len(p["cards"]) == 1 for p in players)
