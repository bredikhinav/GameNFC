from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app import schemas
from app.db import get_db
from app.deps import current_user, membership
from app.errors import not_found
from app.models import Transaction, User
from app.services import ledger, operations
from app.services.views import tx_result

router = APIRouter(tags=["transactions"])


@router.post("/transactions", response_model=schemas.TxResult)
async def create_transaction(
    data: schemas.TxIn, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    """One terminal operation. Safe to retry with the same `id`."""
    space = await membership(db, user, data.space_id, "operator")
    posted = await operations.apply_transaction(db, space, data, user, strict=True)
    await db.commit()
    return await tx_result(db, posted)


@router.post("/transactions/{tx_id}/comment", response_model=schemas.TxOut)
async def set_comment(
    tx_id: UUID,
    data: schemas.CommentIn,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    """A comment typed after the operation ("Покупка улицы"). Amounts never change."""
    tx = await db.get(Transaction, tx_id)
    if tx is None:
        raise not_found("transaction_not_found")
    await membership(db, user, tx.space_id, "operator")
    tx.seq = await ledger.bump_seq(db, tx.space_id)
    tx.comment = data.comment
    await db.commit()
    return tx
