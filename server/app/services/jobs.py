"""Background jobs run by cron: recurring allowances and ledger reconciliation."""

import logging
import uuid
from datetime import datetime
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Allowance, Player, Space, Wallet
from app.security import now
from app.services import ledger

log = logging.getLogger("fantikpay.jobs")
ALLOWANCE_NS = uuid.UUID("0c6e1f4a-8f47-4a7c-b1f2-6a3d9e5b7c21")


async def run_allowances(db: AsyncSession, at: datetime | None = None) -> int:
    """Credit every allowance due today (in the space's time zone). Idempotent per day."""
    at = at or now()
    posted = 0
    allowances = (await db.scalars(select(Allowance).where(Allowance.active.is_(True)))).all()
    for allowance in allowances:
        space = await db.get(Space, allowance.space_id)
        local = at.astimezone(ZoneInfo(space.timezone))
        today = local.date()
        if local.weekday() != allowance.weekday or allowance.last_run_on == today:
            continue
        if allowance.player_id:
            player_ids = [allowance.player_id]
        else:
            player_ids = list(
                await db.scalars(
                    select(Player.id).where(
                        Player.space_id == space.id, Player.deleted_at.is_(None)
                    )
                )
            )
        seq = await ledger.bump_seq(db, space.id)
        await db.refresh(space)
        for player_id in player_ids:
            tx_id = uuid.uuid5(ALLOWANCE_NS, f"{allowance.id}:{today}:{player_id}")
            if await ledger.existing(db, tx_id, space.id, "allowance"):
                continue
            await ledger.post(
                db,
                space=space,
                seq=seq,
                tx_id=tx_id,
                tx_type="allowance",
                from_wallet_id=ledger.system_wallet_id(space.id, "bank"),
                to_wallet_id=ledger.persistent_wallet_id(player_id),
                amount=allowance.amount,
                created_at=at,
                strict=True,
                comment=allowance.comment,
            )
            posted += 1
        allowance.last_run_on = today
        await db.commit()
    return posted


async def reconcile(db: AsyncSession, fix: bool = False) -> int:
    """Nightly check: cached balances must equal the ledger and each space must sum to zero."""
    problems = 0
    for space_id in await db.scalars(select(Space.id)):
        for wallet_id, cached, actual in await ledger.recompute_balances(db, space_id):
            problems += 1
            log.error("wallet %s: cached=%s ledger=%s", wallet_id, cached, actual)
            if fix:
                seq = await ledger.bump_seq(db, space_id)
                wallet = await db.get(Wallet, wallet_id)
                wallet.balance = actual
                wallet.flagged = True
                wallet.flag_reason = "reconciled"
                wallet.seq = seq
        total = sum(await db.scalars(select(Wallet.balance).where(Wallet.space_id == space_id)))
        if total != 0:
            problems += 1
            log.error("space %s: wallets sum to %s", space_id, total)
    await db.commit()
    return problems
