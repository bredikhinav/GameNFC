"""Building API responses from ORM rows (batched, no N+1 queries)."""

import uuid
from collections import defaultdict
from datetime import datetime

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app import schemas
from app.models import Card, Player, PlayerDevice, SavingsGoal, Space, Transaction, Wallet
from app.services import ledger


def space_out(space: Space, role: str | None = None) -> schemas.SpaceOut:
    out = schemas.SpaceOut.model_validate(space)
    out.role = role
    return out


def brief(player: Player | None) -> schemas.PlayerBrief | None:
    if player is None:
        return None
    return schemas.PlayerBrief(id=player.id, name=player.name, avatar=player.avatar)


async def players_out(db: AsyncSession, players: list[Player]) -> list[schemas.PlayerOut]:
    if not players:
        return []
    ids = [p.id for p in players]
    wallets = {
        w.player_id: w
        for w in await db.scalars(
            select(Wallet).where(Wallet.player_id.in_(ids), Wallet.kind == "persistent")
        )
    }
    cards: dict[uuid.UUID, list[Card]] = defaultdict(list)
    for card in await db.scalars(
        select(Card).where(Card.player_id.in_(ids)).order_by(Card.activated_at)
    ):
        cards[card.player_id].append(card)
    devices = dict(
        (
            await db.execute(
                select(PlayerDevice.player_id, func.count())
                .where(PlayerDevice.player_id.in_(ids), PlayerDevice.revoked_at.is_(None))
                .group_by(PlayerDevice.player_id)
            )
        ).all()
    )
    goals = {
        g.player_id: g
        for g in await db.scalars(select(SavingsGoal).where(SavingsGoal.player_id.in_(ids)))
    }

    result = []
    for p in players:
        wallet = wallets.get(p.id)
        goal = goals.get(p.id)
        result.append(
            schemas.PlayerOut(
                id=p.id,
                space_id=p.space_id,
                name=p.name,
                avatar=p.avatar,
                birth_year=p.birth_year,
                group_name=p.group_name,
                balance=wallet.balance if wallet else 0,
                wallet_id=wallet.id if wallet else None,
                flagged=wallet.flagged if wallet else False,
                cards=[schemas.CardBrief.model_validate(c) for c in cards[p.id]],
                linked_devices=devices.get(p.id, 0),
                goal=schemas.GoalOut.model_validate(goal) if goal else None,
                deleted=p.deleted_at is not None,
            )
        )
    return result


def balance_out(wallet: Wallet) -> schemas.WalletBalance:
    return schemas.WalletBalance(
        wallet_id=wallet.id,
        kind=wallet.kind,
        player_id=wallet.player_id,
        session_id=wallet.session_id,
        balance=wallet.balance,
        flagged=wallet.flagged,
    )


async def tx_result(db: AsyncSession, posted: ledger.Posted) -> schemas.TxResult:
    tx = posted.transaction
    wallets = (
        await db.scalars(select(Wallet).where(Wallet.id.in_([tx.from_wallet_id, tx.to_wallet_id])))
    ).all()
    by_id = {w.id: w for w in wallets}
    source, target = by_id[tx.from_wallet_id], by_id[tx.to_wallet_id]

    # "player" is the card holder the operation was about; "to_player" the transfer receiver.
    player_wallet, other = (
        (target, source)
        if tx.type in ("credit", "session_start", "prize", "allowance")
        else (source, target)
    )
    if tx.type == "reversal":
        player_wallet, other = (source, target) if source.player_id else (target, source)
    player = await db.get(Player, player_wallet.player_id) if player_wallet.player_id else None
    to_player = (
        await db.get(Player, other.player_id)
        if tx.type in ("transfer", "reversal") and other.player_id
        else None
    )
    return schemas.TxResult(
        transaction=schemas.TxOut.model_validate(tx),
        balances=[balance_out(w) for w in wallets if w.player_id is not None],
        player=brief(player),
        to_player=brief(to_player),
        duplicate=posted.duplicate,
    )


async def history(
    db: AsyncSession,
    wallet_ids: list[uuid.UUID],
    *,
    limit: int = 50,
    before: datetime | None = None,
    session_id: uuid.UUID | None = None,
) -> list[schemas.HistoryItem]:
    if not wallet_ids:
        return []
    q = select(Transaction).where(
        or_(Transaction.from_wallet_id.in_(wallet_ids), Transaction.to_wallet_id.in_(wallet_ids))
    )
    if session_id is not None:
        q = q.where(Transaction.session_id == session_id)
    if before is not None:
        q = q.where(Transaction.created_at < before)
    txs = (
        await db.scalars(q.order_by(Transaction.created_at.desc(), Transaction.id).limit(limit))
    ).all()
    if not txs:
        return []

    other_wallets = {t.from_wallet_id for t in txs} | {t.to_wallet_id for t in txs}
    wallet_owner = dict(
        (
            await db.execute(
                select(Wallet.id, Wallet.player_id).where(Wallet.id.in_(other_wallets))
            )
        ).all()
    )
    owners = {pid for pid in wallet_owner.values() if pid}
    players = {p.id: p for p in await db.scalars(select(Player).where(Player.id.in_(owners)))}
    reversed_ids = set(
        await db.scalars(
            select(Transaction.reverses_id).where(Transaction.reverses_id.in_([t.id for t in txs]))
        )
    )
    mine = set(wallet_ids)
    items = []
    for t in txs:
        incoming = t.to_wallet_id in mine
        other_wallet = t.from_wallet_id if incoming else t.to_wallet_id
        other_player = (
            players.get(wallet_owner.get(other_wallet)) if wallet_owner.get(other_wallet) else None
        )
        items.append(
            schemas.HistoryItem(
                id=t.id,
                type=t.type,
                amount=t.amount,
                direction="in" if incoming else "out",
                signed_amount=t.amount if incoming else -t.amount,
                session_id=t.session_id,
                comment=t.comment,
                counterparty=brief(other_player),
                created_at=t.created_at,
                reversed=t.id in reversed_ids,
            )
        )
    return items
