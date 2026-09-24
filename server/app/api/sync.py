from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app import schemas
from app.config import get_settings
from app.db import get_db
from app.deps import current_user, membership
from app.errors import AppError
from app.models import (
    Card,
    Device,
    GameSession,
    Player,
    Product,
    SessionParticipant,
    Space,
    Transaction,
    User,
    Wallet,
)
from app.security import now
from app.services import operations
from app.services.views import balance_out, players_out, space_out

from .spaces import templates_for

router = APIRouter(tags=["sync"])


async def _apply(db: AsyncSession, space: Space, op: schemas.SyncOp, user: User) -> bool:
    """Apply one queued op. Returns True if it had already been applied (duplicate)."""
    if op.kind == "transaction":
        if op.transaction is None:
            raise AppError("invalid_op", 422)
        posted = await operations.apply_transaction(db, space, op.transaction, user, strict=False)
        return posted.duplicate
    if op.kind == "session.create":
        if op.session is None:
            raise AppError("invalid_op", 422)
        await operations.create_session(db, space, op.session, user)
        return False
    if op.session_id is None:
        raise AppError("invalid_op", 422)
    if op.kind == "session.join":
        if op.join is None:
            raise AppError("invalid_op", 422)
        *_, joined = await operations.join_session(db, space, op.session_id, op.join, user)
        return not joined
    if op.kind == "session.status":
        if op.status is None:
            raise AppError("invalid_op", 422)
        await operations.set_session_status(db, space, op.session_id, op.status)
        return False
    await operations.finish_session(db, space, op.session_id, op.finish or schemas.FinishIn(), user)
    return False


@router.post("/sync", response_model=schemas.SyncOut)
async def sync(
    data: schemas.SyncIn, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    """Push the offline queue (in order), then pull everything changed after `cursor`.

    Each op runs in its own database transaction: one rejected op does not block the rest.
    Offline transactions are accepted even if they overdraw a wallet (the money was already
    spent in real life); such wallets are flagged for an administrator.
    """
    space = await membership(db, user, data.space_id, "operator")
    space_id, user_id = space.id, user.id

    results: list[schemas.SyncOpResult] = []
    for index, op in enumerate(data.ops):
        try:
            duplicate = await _apply(db, space, op, user)
            await db.commit()
            results.append(schemas.SyncOpResult(index=index, ok=True, duplicate=duplicate))
        except AppError as e:
            await db.rollback()
            results.append(schemas.SyncOpResult(index=index, ok=False, error=e.code))
            # Rollback expires loaded rows; load them again for the next op.
            user = await db.get(User, user_id, populate_existing=True)
        space = await db.get(Space, space_id, populate_existing=True)

    await db.execute(
        insert(Device)
        .values(
            id=data.device_id,
            space_id=space_id,
            user_id=user_id,
            name=data.device_name,
            last_sync_at=now(),
            pending_ops=0,
        )
        .on_conflict_do_update(
            index_elements=[Device.id, Device.space_id],
            set_={
                "last_sync_at": now(),
                "pending_ops": 0,
                "name": data.device_name,
                "user_id": user_id,
            },
        )
    )
    await db.commit()

    space = await db.get(Space, space_id, populate_existing=True)
    current = space.seq
    cursor = min(data.cursor, current)
    upto = min(current, cursor + get_settings().sync_page_size)

    def window(model):
        return select(model).where(
            model.space_id == space_id, model.seq > cursor, model.seq <= upto
        )

    players = (await db.scalars(window(Player))).all()
    changes = schemas.SyncChanges(
        space=space_out(space) if cursor < space.updated_seq <= upto or cursor == 0 else None,
        players=await players_out(db, list(players)),
        cards=[schemas.CardOut.model_validate(c) for c in await db.scalars(window(Card))],
        wallets=[balance_out(w) for w in await db.scalars(window(Wallet))],
        sessions=[
            schemas.SessionOut.model_validate(s) for s in await db.scalars(window(GameSession))
        ],
        participants=[
            schemas.ParticipantOut.model_validate(p)
            for p in await db.scalars(window(SessionParticipant))
        ],
        transactions=[
            schemas.TxOut.model_validate(t)
            for t in await db.scalars(window(Transaction).order_by(Transaction.seq))
        ],
        templates=await templates_for(db, space_id) if cursor == 0 else [],
        products=[schemas.ProductOut.model_validate(p) for p in await db.scalars(window(Product))],
    )
    return schemas.SyncOut(results=results, cursor=upto, has_more=upto < current, changes=changes)
