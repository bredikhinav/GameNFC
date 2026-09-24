from fastapi import Request
from fastapi.responses import JSONResponse


class AppError(Exception):
    """Business error with a stable machine-readable code the app can translate."""

    def __init__(self, code: str, status_code: int = 400, message: str = "", **details):
        super().__init__(code)
        self.code = code
        self.status_code = status_code
        self.message = message or code
        self.details = details


def not_found(what: str = "not_found") -> AppError:
    return AppError(what, 404)


def forbidden() -> AppError:
    return AppError("forbidden", 403)


async def app_error_handler(_: Request, exc: AppError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": {"code": exc.code, "message": exc.message, "details": exc.details}},
    )
