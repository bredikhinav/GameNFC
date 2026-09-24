"""Child mode: a child's phone linked to a player. It sees its own data and makes transfers."""

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request, Response
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app import schemas
from app.db import get_db
from app.deps import ChildAuth, current_child
from app.errors import AppError
from app.models import (
    DeviceLink,
    GameSession,
    Player,
    PlayerDevice,
    SavingsGoal,
    SessionParticipant,
    TransferRequest,
    Wallet,
)
from app.redis import hit
from app.security import PLAYER_TOKEN_PREFIX, now, random_token, sha256
from app.services import ledger, operations
from app.services.views import brief, history, space_out

router = APIRouter(tags=["child"])


@router.post("/device-link/claim", response_model=schemas.ClaimOut)
async def claim(data: schemas.ClaimIn, request: Request, db: AsyncSession = Depends(get_db)):
    ip = request.client.host if request.client else "unknown"
    await hit(f"claim:{ip}", 10)
    link = await db.scalar(
        select(DeviceLink)
        .where(DeviceLink.code_hash == sha256(data.code.strip().upper()))
        .with_for_update()
    )
    if link is None or link.used_at is not None or link.expires_at < now():
        raise AppError("invalid_code", 400)
    player = await db.get(Player, link.player_id)
    if player is None or player.deleted_at is not None:
        raise AppError("invalid_code", 400)
    link.used_at = now()
    token = PLAYER_TOKEN_PREFIX + random_token(40)
    db.add(PlayerDevice(player_id=player.id, name=data.device_name, token_hash=sha256(token)))
    await db.commit()
    return schemas.ClaimOut(token=token, player=brief(player), space_id=player.space_id)


async def _active_game(db: AsyncSession, player: Player) -> schemas.ActiveGame | None:
    row = (
        await db.execute(
            select(GameSession, SessionParticipant)
            .join(SessionParticipant, SessionParticipant.session_id == GameSession.id)
            .where(
                SessionParticipant.player_id == player.id,
                GameSession.status.in_(("active", "paused", "lobby")),
            )
            .order_by(GameSession.created_at.desc())
            .limit(1)
        )
    ).first()
    if row is None:
        return None
    session, participant = row
    standings = await operations.standings(db, session)
    me = next(s for s in standings if s.player_id == player.id)
    wallet = await db.get(Wallet, participant.wallet_id)
    return schemas.ActiveGame(
        session_id=session.id,
        name=session.name,
        balance=wallet.balance if wallet else 0,
        place=me.place,
        players=len(standings),
    )


@router.get("/me", response_model=schemas.MeOut)
async def me(auth: ChildAuth = Depends(current_child), db: AsyncSession = Depends(get_db)):
    player, space = auth.player, auth.space
    wallet = await db.get(Wallet, ledger.persistent_wallet_id(player.id))
    goal = await db.get(SavingsGoal, player.id)
    peers = (
        await db.scalars(
            select(Player)
            .where(
                Player.space_id == space.id,
                Player.id != player.id,
                Player.deleted_at.is_(None),
                # In a camp only the child's own squad is offered; anyone else goes by card.
                (Player.group_name == player.group_name)
                if player.group_name
                else Player.id.is_not(None),
            )
            .order_by(Player.name)
            .limit(50)
        )
    ).all()
    wallet_ids = list(await db.scalars(select(Wallet.id).where(Wallet.player_id == player.id)))
    pending = await db.scalar(
        select(func.count()).where(
            TransferRequest.from_player_id == player.id, TransferRequest.status == "pending"
        )
    )
    return schemas.MeOut(
        player=brief(player),
        space=space_out(space),
        balance=wallet.balance if wallet else 0,
        goal=schemas.GoalOut.model_validate(goal) if goal else None,
        active_game=await _active_game(db, player),
        peers=[brief(p) for p in peers],
        transferred_today=await operations.transferred_today(db, space, player),
        daily_transfer_limit=space.daily_transfer_limit,
        transfer_approval_threshold=space.transfer_approval_threshold,
        recent=await history(db, wallet_ids, limit=5),
        pending_requests=pending or 0,
    )


@router.get("/me/history", response_model=list[schemas.HistoryItem])
async def my_history(
    before: datetime | None = None,
    session_id: UUID | None = None,
    limit: int = Query(default=50, ge=1, le=200),
    auth: ChildAuth = Depends(current_child),
    db: AsyncSession = Depends(get_db),
):
    wallet_ids = list(await db.scalars(select(Wallet.id).where(Wallet.player_id == auth.player.id)))
    return await history(db, wallet_ids, limit=limit, before=before, session_id=session_id)


@router.post("/me/transfers", response_model=schemas.ChildTransferOut)
async def my_transfer(
    data: schemas.ChildTransferIn,
    auth: ChildAuth = Depends(current_child),
    db: AsyncSession = Depends(get_db),
):
    await hit(f"child-transfer:{auth.device.id}", 30)
    result = await operations.child_transfer(db, auth.space, auth.player, auth.device, data)
    await db.commit()
    return result


@router.put("/me/goal", response_model=schemas.GoalOut)
async def my_goal(
    data: schemas.GoalIn,
    auth: ChildAuth = Depends(current_child),
    db: AsyncSession = Depends(get_db),
):
    goal = await db.get(SavingsGoal, auth.player.id)
    if goal is None:
        goal = SavingsGoal(player_id=auth.player.id, **data.model_dump())
        db.add(goal)
    else:
        goal.title, goal.target_amount = data.title, data.target_amount
    player = await db.get(Player, auth.player.id)
    player.seq = await ledger.bump_seq(db, auth.space.id)
    await db.commit()
    return goal


@router.post("/me/logout", status_code=204)
async def unlink_self(auth: ChildAuth = Depends(current_child), db: AsyncSession = Depends(get_db)):
    device = await db.get(PlayerDevice, auth.device.id)
    device.revoked_at = now()
    await db.commit()
    return Response(status_code=204)
