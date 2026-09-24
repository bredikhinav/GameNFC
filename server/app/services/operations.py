"""Business operations shared by the online endpoints and offline sync.

Functions here do not commit; the caller commits (one database transaction per operation).
"""

import uuid
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app import schemas
from app.errors import AppError, not_found
from app.models import (
    GameSession,
    Player,
    PlayerDevice,
    Product,
    SessionParticipant,
    Space,
    Transaction,
    TransferRequest,
    User,
    Wallet,
)
from app.security import now
from app.services import ledger

# Device clocks drift; a far-future timestamp would break history ordering.
MAX_CLOCK_SKEW = timedelta(minutes=10)


def device_time(value: datetime | None) -> datetime:
    current = now()
    if value is None:
        return current
    if value.tzinfo is None:
        raise AppError("timezone_required", 422)
    return min(value, current + MAX_CLOCK_SKEW)


async def _subject(
    db: AsyncSession,
    space_id: uuid.UUID,
    *,
    token: str | None,
    uid: str | None,
    player_id: uuid.UUID | None,
    at: datetime,
) -> tuple[Player, uuid.UUID | None]:
    if token or uid:
        player, card = await ledger.player_from_card(db, space_id, token=token, uid=uid, at=at)
        return player, card.id
    if player_id:
        return await ledger.get_player(db, space_id, player_id), None
    raise AppError("player_required", 422)


# --- Terminal operations ----------------------------------------------------------


async def apply_transaction(
    db: AsyncSession, space: Space, tx: schemas.TxIn, operator: User, *, strict: bool
) -> ledger.Posted:
    if tx.space_id != space.id:
        raise AppError("space_mismatch", 422)
    if (dup := await ledger.existing(db, tx.id, space.id, tx.type)) is not None:
        return dup
    seq = await ledger.bump_seq(db, space.id)
    # Re-check under the space lock: a concurrent retry of the same id may have won.
    if (dup := await ledger.existing(db, tx.id, space.id, tx.type)) is not None:
        return dup
    await db.refresh(space)

    at = device_time(tx.created_at)
    common = dict(
        space=space,
        seq=seq,
        tx_id=tx.id,
        tx_type=tx.type,
        created_at=at,
        strict=strict,
        operator_id=operator.id,
        device_id=tx.device_id,
        comment=tx.comment,
    )

    if tx.type == "reversal":
        return await _reverse(db, tx, common)

    session = await ledger.get_session(db, space.id, tx.session_id) if tx.session_id else None
    if session is not None:
        ledger.require_running(session)

    player, card_id = await _subject(
        db, space.id, token=tx.card_token, uid=tx.card_uid, player_id=tx.player_id, at=at
    )
    wallet_id = await ledger.wallet_for(db, player, session)
    bank = ledger.system_wallet_id(space.id, "bank")
    shop = ledger.system_wallet_id(space.id, "shop")
    session_id = session.id if session else None

    if tx.type == "purchase":
        if tx.product_id is None:
            raise AppError("product_required", 422)
        product = await db.get(Product, tx.product_id, with_for_update=True)
        if product is None or product.space_id != space.id or not product.active:
            raise not_found("product_not_found")
        if product.stock is not None:
            if product.stock <= 0 and strict:
                raise AppError("out_of_stock", 409)
            product.stock = max(product.stock - 1, 0)
            product.seq = seq
        return await ledger.post(
            db,
            **common,
            from_wallet_id=wallet_id,
            to_wallet_id=shop,
            amount=product.price,
            session_id=session_id,
            card_id=card_id,
        )

    if tx.amount is None:
        raise AppError("amount_required", 422)

    if tx.type == "credit":
        return await ledger.post(
            db,
            **common,
            from_wallet_id=bank,
            to_wallet_id=wallet_id,
            amount=tx.amount,
            session_id=session_id,
            card_id=card_id,
        )
    if tx.type == "debit":
        return await ledger.post(
            db,
            **common,
            from_wallet_id=wallet_id,
            to_wallet_id=bank,
            amount=tx.amount,
            session_id=session_id,
            card_id=card_id,
        )

    # transfer
    receiver, _ = await _subject(
        db, space.id, token=tx.to_card_token, uid=tx.to_card_uid, player_id=tx.to_player_id, at=at
    )
    if receiver.id == player.id:
        raise AppError("same_player", 422)
    to_wallet = await ledger.wallet_for(db, receiver, session)
    return await ledger.post(
        db,
        **common,
        from_wallet_id=wallet_id,
        to_wallet_id=to_wallet,
        amount=tx.amount,
        session_id=session_id,
        card_id=card_id,
    )


async def _reverse(db: AsyncSession, tx: schemas.TxIn, common: dict) -> ledger.Posted:
    if tx.reverses_id is None:
        raise AppError("reverses_id_required", 422)
    space: Space = common["space"]
    original = await db.get(Transaction, tx.reverses_id)
    if original is None or original.space_id != space.id:
        raise not_found("transaction_not_found")
    if original.type == "reversal":
        raise AppError("cannot_reverse_reversal", 409)
    already = await db.scalar(select(Transaction.id).where(Transaction.reverses_id == original.id))
    if already is not None:
        raise AppError("already_reversed", 409)
    if original.session_id is not None:
        session = await db.get(GameSession, original.session_id)
        if session is not None and session.status == "finished":
            raise AppError("session_finished", 409)
    return await ledger.post(
        db,
        **common,
        from_wallet_id=original.to_wallet_id,
        to_wallet_id=original.from_wallet_id,
        amount=original.amount,
        session_id=original.session_id,
        card_id=original.card_id,
        reverses_id=original.id,
    )


# --- Game sessions ----------------------------------------------------------------


async def create_session(
    db: AsyncSession, space: Space, data: schemas.SessionIn, user: User
) -> GameSession:
    found = await db.get(GameSession, data.id)
    if found is not None:
        if found.space_id != space.id:
            raise AppError("id_conflict", 409)
        return found
    seq = await ledger.bump_seq(db, space.id)
    session = GameSession(
        id=data.id,
        space_id=space.id,
        template_id=data.template_id,
        name=data.name,
        money_mode=data.money_mode,
        starting_capital=data.starting_capital if data.money_mode == "reset" else 0,
        quick_buttons=[b.model_dump() for b in data.quick_buttons],
        status="lobby",
        created_by=user.id,
        device_id=data.device_id,
        created_at=device_time(data.created_at),
        seq=seq,
    )
    db.add(session)
    await db.flush()
    return session


async def join_session(
    db: AsyncSession, space: Space, session_id: uuid.UUID, data: schemas.JoinIn, user: User
) -> tuple[SessionParticipant, Player, ledger.Posted | None, bool]:
    """Returns (participant, player, starting-capital posting, joined_now)."""
    session = await ledger.get_session(db, space.id, session_id)
    at = device_time(data.joined_at)
    player, _ = await _subject(
        db, space.id, token=data.card_token, uid=data.card_uid, player_id=data.player_id, at=at
    )
    participant = await db.get(SessionParticipant, (session.id, player.id))
    if participant is not None:
        return participant, player, None, False
    if session.status == "finished":
        raise AppError("session_finished", 409)

    seq = await ledger.bump_seq(db, space.id)
    session = await ledger.get_session(db, space.id, session_id)
    if (participant := await db.get(SessionParticipant, (session.id, player.id))) is not None:
        return participant, player, None, False

    if session.money_mode == "reset":
        wallet_id = ledger.session_wallet_id(session.id, player.id)
        db.add(
            Wallet(
                id=wallet_id,
                space_id=space.id,
                kind="session",
                player_id=player.id,
                session_id=session.id,
                seq=seq,
            )
        )
        await db.flush()
    else:
        wallet_id = ledger.persistent_wallet_id(player.id)
    participant = SessionParticipant(
        session_id=session.id,
        player_id=player.id,
        wallet_id=wallet_id,
        space_id=space.id,
        joined_at=at,
        seq=seq,
    )
    db.add(participant)
    await db.flush()

    posted = None
    if session.money_mode == "reset" and session.starting_capital > 0:
        posted = await ledger.post(
            db,
            space=space,
            seq=seq,
            tx_id=data.transaction_id,
            tx_type="session_start",
            from_wallet_id=ledger.system_wallet_id(space.id, "bank"),
            to_wallet_id=wallet_id,
            amount=session.starting_capital,
            created_at=at,
            strict=True,
            session_id=session.id,
            operator_id=user.id,
            device_id=data.device_id,
            comment=session.name,
        )
    return participant, player, posted, True


_TRANSITIONS = {
    ("lobby", "active"),
    ("active", "paused"),
    ("paused", "active"),
}


async def set_session_status(
    db: AsyncSession, space: Space, session_id: uuid.UUID, data: schemas.StatusIn
) -> GameSession:
    session = await ledger.get_session(db, space.id, session_id)
    # A replayed offline queue may resend status changes of a game that has since finished.
    if session.status in (data.status, "finished"):
        return session
    if (session.status, data.status) not in _TRANSITIONS:
        raise AppError("invalid_status_transition", 409, current=session.status)
    seq = await ledger.bump_seq(db, space.id)
    session = await ledger.get_session(db, space.id, session_id)
    session.status = data.status
    if data.status == "active" and session.started_at is None:
        session.started_at = device_time(data.at)
    session.seq = seq
    await db.flush()
    return session


async def finish_session(
    db: AsyncSession, space: Space, session_id: uuid.UUID, data: schemas.FinishIn, user: User
) -> GameSession:
    session = await ledger.get_session(db, space.id, session_id)
    if session.status == "finished":
        return session
    seq = await ledger.bump_seq(db, space.id)
    await db.refresh(space)
    session = await ledger.get_session(db, space.id, session_id)
    at = device_time(data.finished_at)
    for prize in data.prizes:
        participant = await db.get(SessionParticipant, (session.id, prize.player_id))
        if participant is None:
            raise AppError("card_not_in_session", 409, player_id=str(prize.player_id))
        if await db.get(Transaction, prize.transaction_id) is not None:
            continue
        await ledger.post(
            db,
            space=space,
            seq=seq,
            tx_id=prize.transaction_id,
            tx_type="prize",
            from_wallet_id=ledger.system_wallet_id(space.id, "bank"),
            to_wallet_id=ledger.persistent_wallet_id(prize.player_id),
            amount=prize.amount,
            created_at=at,
            strict=True,
            session_id=session.id,
            operator_id=user.id,
            device_id=data.device_id,
            comment=session.name,
        )
    session.status = "finished"
    session.finished_at = at
    session.started_at = session.started_at or at
    session.seq = seq
    await db.flush()
    return session


async def standings(db: AsyncSession, session: GameSession) -> list[schemas.Standing]:
    """Ranking: by balance in reset games, by net gain during the game otherwise."""
    rows = (
        await db.execute(
            select(SessionParticipant, Player, Wallet)
            .join(Player, Player.id == SessionParticipant.player_id)
            .join(Wallet, Wallet.id == SessionParticipant.wallet_id)
            .where(SessionParticipant.session_id == session.id)
        )
    ).all()
    wallet_ids = [w.id for _, _, w in rows]
    net: dict[uuid.UUID, int] = dict.fromkeys(wallet_ids, 0)
    if wallet_ids:
        txs = await db.execute(
            select(Transaction.from_wallet_id, Transaction.to_wallet_id, Transaction.amount).where(
                Transaction.session_id == session.id,
                Transaction.type != "session_start",
                Transaction.type != "prize",
            )
        )
        for src, dst, amount in txs:
            if src in net:
                net[src] -= amount
            if dst in net:
                net[dst] += amount
    items = [
        (p, w.balance if session.money_mode == "reset" else net[w.id], w.balance, net[w.id])
        for _, p, w in rows
    ]
    items.sort(key=lambda i: (-i[1], i[0].name))
    result = []
    for index, (p, _, balance, n) in enumerate(items):
        result.append(
            schemas.Standing(
                place=index + 1,
                player_id=p.id,
                name=p.name,
                avatar=p.avatar,
                balance=balance,
                net=n,
            )
        )
    return result


# --- Child mode -------------------------------------------------------------------


def _local_midnight(space: Space) -> datetime:
    local = now().astimezone(ZoneInfo(space.timezone))
    return local.replace(hour=0, minute=0, second=0, microsecond=0)


async def transferred_today(db: AsyncSession, space: Space, player: Player) -> int:
    wallet_id = ledger.persistent_wallet_id(player.id)
    done = await db.scalar(
        select(func.coalesce(func.sum(Transaction.amount), 0)).where(
            Transaction.from_wallet_id == wallet_id,
            Transaction.type == "transfer",
            Transaction.player_device_id.is_not(None),
            Transaction.created_at >= _local_midnight(space),
        )
    )
    pending = await db.scalar(
        select(func.coalesce(func.sum(TransferRequest.amount), 0)).where(
            TransferRequest.from_player_id == player.id,
            TransferRequest.status == "pending",
        )
    )
    return int(done or 0) + int(pending or 0)


async def child_transfer(
    db: AsyncSession,
    space: Space,
    player: Player,
    device: PlayerDevice,
    data: schemas.ChildTransferIn,
) -> schemas.ChildTransferOut:
    wallet_id = ledger.persistent_wallet_id(player.id)

    # Idempotency for both outcomes.
    if (tx := await db.get(Transaction, data.id)) is not None:
        if tx.from_wallet_id != wallet_id:
            raise AppError("id_conflict", 409)
        wallet = await db.get(Wallet, wallet_id, populate_existing=True)
        return schemas.ChildTransferOut(status="done", balance=wallet.balance, transaction_id=tx.id)
    if (req := await db.get(TransferRequest, data.id)) is not None:
        if req.from_player_id != player.id:
            raise AppError("id_conflict", 409)
        wallet = await db.get(Wallet, wallet_id, populate_existing=True)
        return schemas.ChildTransferOut(
            status="pending_approval", balance=wallet.balance, request_id=req.id
        )

    seq = await ledger.bump_seq(db, space.id)
    await db.refresh(space)
    if data.to_card_token:
        receiver, _ = await ledger.player_from_card(db, space.id, token=data.to_card_token)
    elif data.to_player_id:
        receiver = await ledger.get_player(db, space.id, data.to_player_id)
    else:
        raise AppError("player_required", 422)
    if receiver.id == player.id:
        raise AppError("same_player", 422)

    if space.daily_transfer_limit is not None:
        used = await transferred_today(db, space, player)
        if used + data.amount > space.daily_transfer_limit:
            raise AppError(
                "limit_exceeded",
                409,
                limit=space.daily_transfer_limit,
                remaining=max(space.daily_transfer_limit - used, 0),
            )

    wallet = (await ledger.lock_wallets(db, [wallet_id]))[wallet_id]
    if wallet.balance < data.amount:
        raise AppError("insufficient_funds", 409, balance=wallet.balance, amount=data.amount)

    threshold = space.transfer_approval_threshold
    if threshold is not None and data.amount > threshold:
        db.add(
            TransferRequest(
                id=data.id,
                space_id=space.id,
                from_player_id=player.id,
                to_player_id=receiver.id,
                amount=data.amount,
                comment=data.comment,
                player_device_id=device.id,
                seq=seq,
            )
        )
        await db.flush()
        return schemas.ChildTransferOut(
            status="pending_approval", balance=wallet.balance, request_id=data.id
        )

    posted = await ledger.post(
        db,
        space=space,
        seq=seq,
        tx_id=data.id,
        tx_type="transfer",
        from_wallet_id=wallet_id,
        to_wallet_id=ledger.persistent_wallet_id(receiver.id),
        amount=data.amount,
        created_at=now(),
        strict=True,
        player_device_id=device.id,
        comment=data.comment,
    )
    return schemas.ChildTransferOut(
        status="done", balance=posted.balances[wallet_id], transaction_id=data.id
    )


async def decide_request(
    db: AsyncSession, space: Space, request_id: uuid.UUID, user: User, approve: bool
) -> TransferRequest:
    seq = await ledger.bump_seq(db, space.id)
    await db.refresh(space)
    req = await db.get(TransferRequest, request_id, with_for_update=True, populate_existing=True)
    if req is None or req.space_id != space.id:
        raise not_found("request_not_found")
    if req.status != "pending":
        raise AppError("request_already_decided", 409, status=req.status)
    req.status = "approved" if approve else "rejected"
    req.decided_by = user.id
    req.decided_at = now()
    req.seq = seq
    if approve:
        # An approved request is a regular transfer; the transaction reuses the request id.
        await ledger.post(
            db,
            space=space,
            seq=seq,
            tx_id=req.id,
            tx_type="transfer",
            from_wallet_id=ledger.persistent_wallet_id(req.from_player_id),
            to_wallet_id=ledger.persistent_wallet_id(req.to_player_id),
            amount=req.amount,
            created_at=now(),
            strict=True,
            operator_id=user.id,
            player_device_id=req.player_device_id,
            comment=req.comment,
        )
        req.transaction_id = req.id
    await db.flush()
    return req
