from datetime import datetime, timedelta
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app import schemas
from app.config import get_settings
from app.db import get_db
from app.deps import current_user, membership, player_in_space
from app.errors import not_found
from app.models import Card, DeviceLink, Player, PlayerDevice, SavingsGoal, User, Wallet
from app.security import now, sha256, short_code
from app.services import ledger
from app.services.views import history, players_out

router = APIRouter(tags=["players"])


@router.get("/spaces/{space_id}/players", response_model=list[schemas.PlayerOut])
async def list_players(
    space_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    await membership(db, user, space_id, "operator")
    players = (
        await db.scalars(
            select(Player)
            .where(Player.space_id == space_id, Player.deleted_at.is_(None))
            .order_by(Player.created_at)
        )
    ).all()
    return await players_out(db, list(players))


@router.post("/spaces/{space_id}/players", response_model=schemas.PlayerOut, status_code=201)
async def create_player(
    space_id: UUID,
    data: schemas.PlayerIn,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    await membership(db, user, space_id, "admin")
    seq = await ledger.bump_seq(db, space_id)
    player = Player(
        space_id=space_id,
        name=data.name.strip(),
        avatar=data.avatar,
        birth_year=data.birth_year,
        group_name=data.group_name,
        consent_user_id=user.id,
        consent_at=now(),
        seq=seq,
    )
    db.add(player)
    await db.flush()
    ledger.create_persistent_wallet(db, player, seq)
    await db.commit()
    return (await players_out(db, [player]))[0]


@router.get("/players/{player_id}", response_model=schemas.PlayerOut)
async def get_player(
    player_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    player, _ = await player_in_space(db, user, player_id, "operator")
    return (await players_out(db, [player]))[0]


@router.patch("/players/{player_id}", response_model=schemas.PlayerOut)
async def update_player(
    player_id: UUID,
    data: schemas.PlayerPatch,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    player, space = await player_in_space(db, user, player_id, "admin")
    seq = await ledger.bump_seq(db, space.id)
    for key, value in data.model_dump(exclude_unset=True).items():
        if key in ("name", "avatar") and value is None:
            continue
        setattr(player, key, value)
    player.seq = seq
    await db.commit()
    return (await players_out(db, [player]))[0]


@router.delete("/players/{player_id}", status_code=204)
async def delete_player(
    player_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    """Delete a child's profile on the parent's request.

    The ledger is immutable, so the row stays but loses all personal data.
    """
    player, space = await player_in_space(db, user, player_id, "admin")
    seq = await ledger.bump_seq(db, space.id)
    player.name = "Удалённый игрок"
    player.avatar = "default"
    player.birth_year = None
    player.group_name = None
    player.deleted_at = now()
    player.seq = seq
    await db.execute(
        update(Card)
        .where(Card.player_id == player.id)
        .values(status="unlinked", player_id=None, seq=seq)
    )
    await db.execute(
        update(PlayerDevice)
        .where(PlayerDevice.player_id == player.id, PlayerDevice.revoked_at.is_(None))
        .values(revoked_at=now())
    )
    goal = await db.get(SavingsGoal, player.id)
    if goal is not None:
        await db.delete(goal)
    await db.commit()
    return Response(status_code=204)


@router.put("/players/{player_id}/goal", response_model=schemas.GoalOut)
async def set_goal(
    player_id: UUID,
    data: schemas.GoalIn,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    player, space = await player_in_space(db, user, player_id, "admin")
    goal = await db.get(SavingsGoal, player.id)
    if goal is None:
        goal = SavingsGoal(player_id=player.id, **data.model_dump())
        db.add(goal)
    else:
        goal.title, goal.target_amount = data.title, data.target_amount
    player.seq = await ledger.bump_seq(db, space.id)
    await db.commit()
    return goal


@router.delete("/players/{player_id}/goal", status_code=204)
async def delete_goal(
    player_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    player, space = await player_in_space(db, user, player_id, "admin")
    goal = await db.get(SavingsGoal, player.id)
    if goal is not None:
        await db.delete(goal)
        player.seq = await ledger.bump_seq(db, space.id)
        await db.commit()
    return Response(status_code=204)


@router.get("/players/{player_id}/history", response_model=list[schemas.HistoryItem])
async def player_history(
    player_id: UUID,
    session_id: UUID | None = None,
    before: datetime | None = None,
    limit: int = Query(default=50, ge=1, le=200),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    player, _ = await player_in_space(db, user, player_id, "operator")
    wallet_ids = list(await db.scalars(select(Wallet.id).where(Wallet.player_id == player.id)))
    return await history(db, wallet_ids, limit=limit, before=before, session_id=session_id)


# --- Child phones -----------------------------------------------------------------


@router.post("/players/{player_id}/device-link", response_model=schemas.DeviceLinkOut)
async def create_device_link(
    player_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    player, _ = await player_in_space(db, user, player_id, "admin")
    code = short_code(8)
    expires = now() + timedelta(seconds=get_settings().device_link_ttl_seconds)
    db.add(
        DeviceLink(
            player_id=player.id, code_hash=sha256(code), created_by=user.id, expires_at=expires
        )
    )
    await db.commit()
    return schemas.DeviceLinkOut(
        code=code, qr_payload=f"fantikpay://link?code={code}", expires_at=expires
    )


@router.get("/players/{player_id}/devices")
async def list_child_devices(
    player_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    player, _ = await player_in_space(db, user, player_id, "admin")
    devices = await db.scalars(
        select(PlayerDevice).where(
            PlayerDevice.player_id == player.id, PlayerDevice.revoked_at.is_(None)
        )
    )
    return [
        {"id": d.id, "name": d.name, "last_seen_at": d.last_seen_at, "created_at": d.created_at}
        for d in devices
    ]


@router.delete("/players/{player_id}/devices/{device_id}", status_code=204)
async def revoke_child_device(
    player_id: UUID,
    device_id: UUID,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    player, _ = await player_in_space(db, user, player_id, "admin")
    device = await db.get(PlayerDevice, device_id)
    if device is None or device.player_id != player.id:
        raise not_found("device_not_found")
    device.revoked_at = now()
    await db.commit()
    return Response(status_code=204)
