from tests.conftest import Api


async def test_register_login_refresh_rotation(client):
    api = Api(client)
    tokens = await api.register("Parent@Example.com")
    me = await api.get("/auth/me")
    assert me["email"] == "parent@example.com"
    assert me["pin"] is None

    status, code = await api.error(
        "POST", "/auth/register", {"email": "parent@example.com", "password": "password123"}
    )
    assert (status, code) == (409, "email_taken")

    login = await api.post(
        "/auth/login", {"email": "PARENT@example.com", "password": "password123"}
    )
    assert login["access_token"]

    status, code = await api.error(
        "POST", "/auth/login", {"email": "parent@example.com", "password": "wrong-pass"}
    )
    assert (status, code) == (401, "invalid_credentials")

    rotated = await api.post("/auth/refresh", {"refresh_token": tokens["refresh_token"]})
    assert rotated["refresh_token"] != tokens["refresh_token"]
    # Reusing a rotated refresh token revokes every session of the user.
    status, code = await api.error(
        "POST", "/auth/refresh", {"refresh_token": tokens["refresh_token"]}
    )
    assert (status, code) == (401, "invalid_refresh_token")
    status, _ = await api.error(
        "POST", "/auth/refresh", {"refresh_token": rotated["refresh_token"]}
    )
    assert status == 401


async def test_unauthorized(client):
    api = Api(client, token="garbage")
    status, code = await api.error("GET", "/spaces")
    assert (status, code) == (401, "unauthorized")


async def test_pin_is_verifiable_offline(api):
    await api.register()
    status, code = await api.error("PUT", "/auth/pin", {"pin": "1234", "password": "nope-nope"})
    assert code == "invalid_credentials"
    me = await api.req("PUT", "/auth/pin", json={"pin": "1234", "password": "password123"})
    from app.security import verify_pin

    pin = me["pin"]
    assert verify_pin("1234", pin["salt"], pin["hash"], pin["iterations"])
    assert not verify_pin("1235", pin["salt"], pin["hash"], pin["iterations"])


async def test_password_reset(api, caplog):
    import logging

    caplog.set_level(logging.INFO, logger="fantikpay.mail")
    await api.register("reset@example.com")
    await api.post("/auth/password/forgot", {"email": "reset@example.com"}, 204)
    # Unknown email gets the same answer.
    await api.post("/auth/password/forgot", {"email": "nobody@example.com"}, 204)
    mail = [r.getMessage() for r in caplog.records if "восстановление" in r.getMessage()][-1]
    token = mail.split("Код для нового пароля: ")[1].split("\n")[0]
    await api.post("/auth/password/reset", {"token": token, "password": "new-password1"}, 204)
    status, _ = await api.error(
        "POST", "/auth/password/reset", {"token": token, "password": "again-again"}
    )
    assert status == 400
    await api.post("/auth/login", {"email": "reset@example.com", "password": "new-password1"})


async def test_login_rate_limit(api):
    await api.register("brute@example.com")
    codes = []
    for _ in range(12):
        status, code = await api.error(
            "POST", "/auth/login", {"email": "brute@example.com", "password": "wrong-pass"}
        )
        codes.append(code)
    assert codes[-1] == "rate_limited"
