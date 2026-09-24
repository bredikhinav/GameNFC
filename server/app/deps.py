from dataclasses import dataclass
from uuid import UUID

from fastapi import Depends, Header
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.errors import AppError, forbidden, not_found
from app.models import Player, PlayerDevice, Space, SpaceMember, User
from app.security import PLAYER_TOKEN_PREFIX, decode_access_token, now, sha256

ROLE_RANK = {"operator": 1, "admin": 2, "owner": 3}


def _bearer(authorization: str | None) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise AppError("unauthorized", 401)
    return authorization.removeprefix("Bearer ").strip()


async def current_user(
    authorization: str | None = Header(default=None), db: AsyncSession = Depends(get_db)
) -> User:
    token = _bearer(authorization)
    user_id = None if token.startswith(PLAYER_TOKEN_PREFIX) else decode_access_token(token)
    if user_id is None:
        raise AppError("unauthorized", 401)
    user = await db.get(User, user_id)
    if user is None:
        raise AppError("unauthorized", 401)
    return user


@dataclass
class ChildAuth:
    device: PlayerDevice
    player: Player
    space: Space


async def current_child(
    authorization: str | None = Header(default=None), db: AsyncSession = Depends(get_db)
) -> ChildAuth:
    token = _bearer(authorization)
    if not token.startswith(PLAYER_TOKEN_PREFIX):
        raise AppError("unauthorized", 401)
    device = await db.scalar(
        select(PlayerDevice).where(
            PlayerDevice.token_hash == sha256(token), PlayerDevice.revoked_at.is_(None)
        )
    )
    if device is None:
        raise AppError("unauthorized", 401)
    player = await db.get(Player, device.player_id)
    if player is None or player.deleted_at is not None:
        raise AppError("unauthorized", 401)
    space = await db.get(Space, player.space_id)
    assert space is not None
    device.last_seen_at = now()
    await db.commit()
    return ChildAuth(device=device, player=player, space=space)


async def membership(db: AsyncSession, user: User, space_id: UUID, min_role: str) -> Space:
    """Return the space if the user has at least `min_role` in it."""
    row = (
        await db.execute(
            select(Space, SpaceMember.role)
            .join(SpaceMember, SpaceMember.space_id == Space.id)
            .where(Space.id == space_id, SpaceMember.user_id == user.id)
        )
    ).first()
    if row is None:
        raise not_found("space_not_found")
    space, role = row
    if ROLE_RANK[role] < ROLE_RANK[min_role]:
        raise forbidden()
    return space


async def player_in_space(
    db: AsyncSession, user: User, player_id: UUID, min_role: str
) -> tuple[Player, Space]:
    player = await db.get(Player, player_id)
    if player is None or player.deleted_at is not None:
        raise not_found("player_not_found")
    space = await membership(db, user, player.space_id, min_role)
    return player, space
