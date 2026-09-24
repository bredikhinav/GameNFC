import logging

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.api import auth, cards, child, players, public, sessions, spaces, sync, transactions
from app.errors import AppError, app_error_handler

logging.basicConfig(level=logging.INFO)

app = FastAPI(
    title="FantikPay API",
    version="0.1.0",
    description="Игровой банк для детей на NFC-картах. Монеты виртуальные.",
)
app.add_exception_handler(AppError, app_error_handler)


@app.exception_handler(RequestValidationError)
async def validation_handler(_, exc: RequestValidationError) -> JSONResponse:
    return JSONResponse(
        status_code=422,
        content={
            "error": {
                "code": "validation_error",
                "message": "invalid request",
                "details": {"errors": jsonable(exc.errors())},
            }
        },
    )


def jsonable(errors: list) -> list:
    return [
        {"loc": list(e.get("loc", [])), "msg": str(e.get("msg")), "type": e.get("type")}
        for e in errors
    ]


@app.get("/health", include_in_schema=False)
async def health() -> dict:
    return {"status": "ok"}


for module in (auth, spaces, players, cards, sessions, transactions, sync, child):
    app.include_router(module.router, prefix="/api/v1")
app.include_router(public.router)
