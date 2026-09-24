"""Ledger: the only place that moves money.

Every write in a space starts with `bump_seq`, which increments the space change counter
with `UPDATE ... RETURNING`. That row lock is held until commit, so writes within one
space are serialized: sequence numbers follow commit order (safe sync cursors), and
balance checks cannot race. Wallet rows are additionally locked with FOR UPDATE.

`strict=True` is used for online operations: business rules reject the operation.
`strict=False` is used for operations that already happened offline: they are accepted,
and a wallet that went below zero is flagged for an administrator.
"""

import uuid
from dataclasses import dataclass, field
from datetime import datetime

from sqlalchemy import select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import AppError, not_found
from app.models import Card, GameSession, Player, SessionParticipant, Space, Transaction, Wallet

WALLET_NS = uuid.UUID("6b1f3f0e-3c5a-4c1e-9a8e-4f0b8f6a2d11")
PLAYER_WALLET_KINDS = ("persistent", "session")


def persistent_wallet_id(player_id: uuid.UUID) -> uuid.UUID:
    return uuid.uuid5(WALLET_NS, f"persistent:{player_id}")


def session_wallet_id(session_id: uuid.UUID, player_id: uuid.UUID) -> uuid.UUID:
    return uuid.uuid5(WALLET_NS, f"session:{session_id}:{player_id}")


def system_wallet_id(space_id: uuid.UUID, kind: str) -> uuid.UUID:
    return uuid.uuid5(WALLET_NS, f"{kind}:{space_id}")


async def bump_seq(db: AsyncSession, space_id: uuid.UUID) -> int:
    seq = await db.scalar(
        update(Space).where(Space.id == space_id).values(seq=Space.seq + 1).returning(Space.seq)
    )
    if seq is None:
        raise not_found("space_not_found")
    return seq


def create_system_wallets(db: AsyncSession, space_id: uuid.UUID, seq: int) -> None:
    for kind in ("bank", "shop"):
        db.add(Wallet(id=system_wallet_id(space_id, kind), space_id=space_id, kind=kind, seq=seq))


def create_persistent_wallet(db: AsyncSession, player: Player, seq: int) -> Wallet:
    wallet = Wallet(
        id=persistent_wallet_id(player.id),
        space_id=player.space_id,
        kind="persistent",
        player_id=player.id,
        seq=seq,
    )
    db.add(wallet)
    return wallet


async def lock_wallets(db: AsyncSession, ids: list[uuid.UUID]) -> dict[uuid.UUID, Wallet]:
    rows = (
        await db.scalars(
            select(Wallet)
            .where(Wallet.id.in_(ids))
            .order_by(Wallet.id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    ).all()
    return {w.id: w for w in rows}


# --- Resolving who pays -----------------------------------------------------------


async def card_by_token(db: AsyncSession, token: str) -> Card | None:
    return await db.scalar(select(Card).where(Card.token == token))


async def card_by_uid(db: AsyncSession, uid: str) -> Card | None:
    return await db.scalar(select(Card).where(Card.uid == uid.upper()))


async def player_from_card(
    db: AsyncSession,
    space_id: uuid.UUID,
    *,
    token: str | None = None,
    uid: str | None = None,
    at: datetime | None = None,
) -> tuple[Player, Card]:
    card = None
    if token:
        card = await card_by_token(db, token)
    if card is None and uid:
        card = await card_by_uid(db, uid)
    if card is None or card.space_id != space_id or card.player_id is None:
        if card is not None and card.space_id == space_id and card.status == "unlinked":
            raise AppError("card_unlinked", 409)
        raise AppError("card_not_found", 404)
    if card.status == "blocked":
        # An offline operation made before the card was blocked still stands.
        if at is None or card.blocked_at is None or at >= card.blocked_at:
            raise AppError("card_blocked", 409)
    player = await db.get(Player, card.player_id)
    if player is None or player.deleted_at is not None:
        raise AppError("card_not_found", 404)
    return player, card


async def get_player(db: AsyncSession, space_id: uuid.UUID, player_id: uuid.UUID) -> Player:
    player = await db.get(Player, player_id)
    if player is None or player.space_id != space_id or player.deleted_at is not None:
        raise not_found("player_not_found")
    return player


async def get_session(db: AsyncSession, space_id: uuid.UUID, session_id: uuid.UUID) -> GameSession:
    session = await db.get(GameSession, session_id, populate_existing=True)
    if session is None or session.space_id != space_id:
        raise not_found("session_not_found")
    return session


async def wallet_for(db: AsyncSession, player: Player, session: GameSession | None) -> uuid.UUID:
    if session is None:
        return persistent_wallet_id(player.id)
    participant = await db.get(SessionParticipant, (session.id, player.id))
    if participant is None:
        raise AppError("card_not_in_session", 409, player_id=str(player.id))
    return participant.wallet_id


def require_running(session: GameSession) -> None:
    if session.status != "active":
        raise AppError("session_not_active", 409, status=session.status)


# --- Posting ----------------------------------------------------------------------


@dataclass
class Posted:
    transaction: Transaction
    balances: dict[uuid.UUID, int] = field(default_factory=dict)
    duplicate: bool = False


async def existing(
    db: AsyncSession, tx_id: uuid.UUID, space_id: uuid.UUID, tx_type: str
) -> Posted | None:
    """Idempotency: the same id sent again returns the original result."""
    tx = await db.get(Transaction, tx_id, populate_existing=True)
    if tx is None:
        return None
    if tx.space_id != space_id or tx.type != tx_type:
        raise AppError("id_conflict", 409)
    wallets = (
        await db.scalars(select(Wallet).where(Wallet.id.in_([tx.from_wallet_id, tx.to_wallet_id])))
    ).all()
    return Posted(tx, {w.id: w.balance for w in wallets}, duplicate=True)


async def post(
    db: AsyncSession,
    *,
    space: Space,
    seq: int,
    tx_id: uuid.UUID,
    tx_type: str,
    from_wallet_id: uuid.UUID,
    to_wallet_id: uuid.UUID,
    amount: int,
    created_at: datetime,
    strict: bool,
    session_id: uuid.UUID | None = None,
    card_id: uuid.UUID | None = None,
    reverses_id: uuid.UUID | None = None,
    operator_id: uuid.UUID | None = None,
    player_device_id: uuid.UUID | None = None,
    device_id: uuid.UUID | None = None,
    comment: str | None = None,
) -> Posted:
    if amount <= 0:
        raise AppError("invalid_amount", 422)
    if from_wallet_id == to_wallet_id:
        raise AppError("same_wallet", 422)

    wallets = await lock_wallets(db, [from_wallet_id, to_wallet_id])
    source, target = wallets.get(from_wallet_id), wallets.get(to_wallet_id)
    if source is None or target is None:
        raise not_found("wallet_not_found")

    if source.kind in PLAYER_WALLET_KINDS and source.balance - amount < 0:
        if strict and not space.allow_negative:
            raise AppError("insufficient_funds", 409, balance=source.balance, amount=amount)
        if not space.allow_negative:
            source.flagged = True
            source.flag_reason = "negative_after_sync"

    source.balance -= amount
    target.balance += amount
    source.seq = target.seq = seq

    tx = Transaction(
        id=tx_id,
        space_id=space.id,
        type=tx_type,
        from_wallet_id=from_wallet_id,
        to_wallet_id=to_wallet_id,
        amount=amount,
        session_id=session_id,
        card_id=card_id,
        reverses_id=reverses_id,
        operator_id=operator_id,
        player_device_id=player_device_id,
        device_id=device_id,
        comment=comment,
        created_at=created_at,
        offline=not strict,
        seq=seq,
    )
    db.add(tx)
    await db.flush()
    return Posted(tx, {source.id: source.balance, target.id: target.balance})


async def recompute_balances(
    db: AsyncSession, space_id: uuid.UUID
) -> list[tuple[uuid.UUID, int, int]]:
    """Compare cached balances with the ledger. Returns [(wallet_id, cached, actual)] mismatches."""
    rows = await db.execute(
        text(
            """
            SELECT w.id, w.balance,
                   COALESCE((SELECT SUM(amount) FROM transactions WHERE to_wallet_id = w.id), 0)
                 - COALESCE((SELECT SUM(amount) FROM transactions WHERE from_wallet_id = w.id), 0)
            FROM wallets w WHERE w.space_id = :space_id
            """
        ),
        {"space_id": space_id},
    )
    return [(r[0], r[1], r[2]) for r in rows if r[1] != r[2]]
