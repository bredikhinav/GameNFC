from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app import schemas
from app.db import get_db
from app.deps import current_user, membership
from app.models import User
from app.services import operations
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
