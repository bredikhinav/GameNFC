from datetime import timedelta

from fastapi import APIRouter, Depends, Request, Response
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app import schemas
from app.config import get_settings
from app.db import get_db
from app.deps import current_user
from app.errors import AppError
from app.mail import send_mail
from app.models import EmailToken, RefreshToken, User
from app.redis import hit, reset
from app.security import (
    create_access_token,
    hash_password,
    hash_pin,
    now,
    random_token,
    sha256,
    verify_password,
)

router = APIRouter(prefix="/auth", tags=["auth"])


def user_out(user: User) -> schemas.UserOut:
    pin = None
    if user.pin_hash and user.pin_salt and user.pin_iterations:
        pin = schemas.PinOut(salt=user.pin_salt, hash=user.pin_hash, iterations=user.pin_iterations)
    return schemas.UserOut(
        id=user.id,
        email=user.email,
        name=user.name,
        locale=user.locale,
        email_verified=user.email_verified_at is not None,
        pin=pin,
    )


async def _issue(db: AsyncSession, user: User) -> schemas.TokenPair:
    s = get_settings()
    refresh = random_token(48)
    db.add(
        RefreshToken(
            user_id=user.id,
            token_hash=sha256(refresh),
            expires_at=now() + timedelta(days=s.refresh_token_ttl_days),
        )
    )
    await db.commit()
    return schemas.TokenPair(
        access_token=create_access_token(user.id),
        refresh_token=refresh,
        expires_in=s.access_token_ttl_seconds,
    )


async def _email_token(db: AsyncSession, user: User, purpose: str) -> str:
    token = random_token(40)
    db.add(
        EmailToken(
            user_id=user.id,
            purpose=purpose,
            token_hash=sha256(token),
            expires_at=now() + timedelta(hours=get_settings().email_token_ttl_hours),
        )
    )
    return token


def _client_ip(request: Request) -> str:
    # Behind Caddy, uvicorn --proxy-headers puts the real client address here; a
    # client-supplied X-Forwarded-For header is not trusted directly.
    return request.client.host if request.client else "unknown"


@router.post("/register", response_model=schemas.TokenPair, status_code=201)
async def register(data: schemas.RegisterIn, request: Request, db: AsyncSession = Depends(get_db)):
    await hit(f"register:{_client_ip(request)}", get_settings().login_rate_limit)
    email = data.email.lower()
    if await db.scalar(select(User.id).where(func.lower(User.email) == email)):
        raise AppError("email_taken", 409)
    user = User(
        email=email, password_hash=hash_password(data.password), name=data.name, locale=data.locale
    )
    db.add(user)
    await db.flush()
    token = await _email_token(db, user, "verify")
    await send_mail(
        email,
        "ФантикПэй: подтвердите почту",
        f"Код подтверждения: {token}\n{get_settings().public_base_url}/verify?token={token}",
    )
    return await _issue(db, user)


@router.post("/login", response_model=schemas.TokenPair)
async def login(data: schemas.LoginIn, request: Request, db: AsyncSession = Depends(get_db)):
    email = data.email.lower()
    limit = get_settings().login_rate_limit
    await hit(f"login:{email}", limit)
    await hit(f"login-ip:{_client_ip(request)}", limit * 5)
    user = await db.scalar(select(User).where(func.lower(User.email) == email))
    if user is None or not verify_password(user.password_hash, data.password):
        raise AppError("invalid_credentials", 401)
    await reset(f"login:{email}")
    return await _issue(db, user)


@router.post("/refresh", response_model=schemas.TokenPair)
async def refresh(data: schemas.RefreshIn, db: AsyncSession = Depends(get_db)):
    token = await db.scalar(
        select(RefreshToken).where(RefreshToken.token_hash == sha256(data.refresh_token))
    )
    if token is None or token.expires_at < now():
        raise AppError("invalid_refresh_token", 401)
    if token.revoked_at is not None:
        # Reuse of a rotated token: someone copied it. Log out every session of the user.
        await db.execute(
            update(RefreshToken)
            .where(RefreshToken.user_id == token.user_id, RefreshToken.revoked_at.is_(None))
            .values(revoked_at=now())
        )
        await db.commit()
        raise AppError("invalid_refresh_token", 401)
    token.revoked_at = now()
    user = await db.get(User, token.user_id)
    assert user is not None
    return await _issue(db, user)


@router.post("/logout", status_code=204)
async def logout(data: schemas.RefreshIn, db: AsyncSession = Depends(get_db)):
    await db.execute(
        update(RefreshToken)
        .where(RefreshToken.token_hash == sha256(data.refresh_token))
        .values(revoked_at=now())
    )
    await db.commit()
    return Response(status_code=204)


@router.get("/me", response_model=schemas.UserOut)
async def me(user: User = Depends(current_user)):
    return user_out(user)


@router.put("/pin", response_model=schemas.UserOut)
async def set_pin(
    data: schemas.PinIn, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    if not verify_password(user.password_hash, data.password):
        raise AppError("invalid_credentials", 401)
    user.pin_salt, user.pin_hash, user.pin_iterations = hash_pin(data.pin)
    await db.commit()
    return user_out(user)


async def _use_email_token(db: AsyncSession, token: str, purpose: str) -> User:
    row = await db.scalar(
        select(EmailToken).where(
            EmailToken.token_hash == sha256(token), EmailToken.purpose == purpose
        )
    )
    if row is None or row.used_at is not None or row.expires_at < now():
        raise AppError("invalid_token", 400)
    row.used_at = now()
    user = await db.get(User, row.user_id)
    assert user is not None
    return user


@router.post("/verify-email", status_code=204)
async def verify_email(data: schemas.TokenIn, db: AsyncSession = Depends(get_db)):
    user = await _use_email_token(db, data.token, "verify")
    user.email_verified_at = user.email_verified_at or now()
    await db.commit()
    return Response(status_code=204)


@router.post("/password/forgot", status_code=204)
async def forgot_password(
    data: schemas.EmailIn, request: Request, db: AsyncSession = Depends(get_db)
):
    await hit(f"forgot:{_client_ip(request)}", get_settings().login_rate_limit)
    user = await db.scalar(select(User).where(func.lower(User.email) == data.email.lower()))
    # Same answer either way: do not reveal which emails are registered.
    if user is not None:
        token = await _email_token(db, user, "reset")
        await db.commit()
        await send_mail(
            user.email,
            "ФантикПэй: восстановление пароля",
            f"Код для нового пароля: {token}\n{get_settings().public_base_url}/reset?token={token}",
        )
    return Response(status_code=204)


@router.post("/password/reset", status_code=204)
async def reset_password(data: schemas.ResetPasswordIn, db: AsyncSession = Depends(get_db)):
    user = await _use_email_token(db, data.token, "reset")
    user.password_hash = hash_password(data.password)
    await db.execute(
        update(RefreshToken)
        .where(RefreshToken.user_id == user.id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=now())
    )
    await db.commit()
    return Response(status_code=204)
