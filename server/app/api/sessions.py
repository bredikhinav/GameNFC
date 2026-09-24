from uuid import UUID

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app import schemas
from app.db import get_db
from app.deps import current_user, membership
from app.errors import not_found
from app.models import GameSession, User
from app.services import operations
from app.services.views import tx_result

router = APIRouter(tags=["sessions"])


async def _detail(db: AsyncSession, session: GameSession) -> schemas.SessionDetail:
    return schemas.SessionDetail(
        **schemas.SessionOut.model_validate(session).model_dump(),
        standings=await operations.standings(db, session),
    )


async def _session_space(db: AsyncSession, user: User, session_id: UUID):
    session = await db.get(GameSession, session_id)
    if session is None:
        raise not_found("session_not_found")
    space = await membership(db, user, session.space_id, "operator")
    return session, space


@router.get("/spaces/{space_id}/sessions", response_model=list[schemas.SessionOut])
async def list_sessions(
    space_id: UUID,
    status: str | None = None,
    limit: int = Query(default=30, ge=1, le=100),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    await membership(db, user, space_id, "operator")
    q = select(GameSession).where(GameSession.space_id == space_id)
    if status == "open":
        q = q.where(GameSession.status != "finished")
    elif status:
        q = q.where(GameSession.status == status)
    return (await db.scalars(q.order_by(GameSession.created_at.desc()).limit(limit))).all()


@router.post("/spaces/{space_id}/sessions", response_model=schemas.SessionDetail, status_code=201)
async def create_session(
    space_id: UUID,
    data: schemas.SessionIn,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    space = await membership(db, user, space_id, "operator")
    session = await operations.create_session(db, space, data, user)
    await db.commit()
    return await _detail(db, session)


@router.get("/sessions/{session_id}", response_model=schemas.SessionDetail)
async def get_session(
    session_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    session, _ = await _session_space(db, user, session_id)
    return await _detail(db, session)


@router.post("/sessions/{session_id}/join")
async def join_session(
    session_id: UUID,
    data: schemas.JoinIn,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    _, space = await _session_space(db, user, session_id)
    participant, player, posted, joined = await operations.join_session(
        db, space, session_id, data, user
    )
    await db.commit()
    return {
        "player_id": player.id,
        "name": player.name,
        "avatar": player.avatar,
        "wallet_id": participant.wallet_id,
        "already_joined": not joined,
        "transaction": (await tx_result(db, posted)).model_dump() if posted else None,
    }


@router.post("/sessions/{session_id}/status", response_model=schemas.SessionDetail)
async def set_status(
    session_id: UUID,
    data: schemas.StatusIn,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    _, space = await _session_space(db, user, session_id)
    session = await operations.set_session_status(db, space, session_id, data)
    await db.commit()
    return await _detail(db, session)


@router.post("/sessions/{session_id}/finish", response_model=schemas.SessionDetail)
async def finish_session(
    session_id: UUID,
    data: schemas.FinishIn,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    _, space = await _session_space(db, user, session_id)
    session = await operations.finish_session(db, space, session_id, data, user)
    await db.commit()
    return await _detail(db, session)
