from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app import schemas
from app.config import get_settings
from app.db import get_db
from app.deps import current_user, membership, player_in_space
from app.errors import AppError, not_found
from app.models import Card, GameSession, SessionParticipant, User, Wallet
from app.redis import hit, is_limited
from app.security import card_token, now, sha256
from app.services import ledger
from app.services.views import balance_out, players_out

router = APIRouter(prefix="/cards", tags=["cards"])


def card_url(token: str) -> str:
    return f"{get_settings().public_base_url}/c/{token}"


@router.post("/prepare", response_model=schemas.CardPrepareOut)
async def prepare_card(user: User = Depends(current_user), db: AsyncSession = Depends(get_db)):
    """Issue a token for a blank card; the app writes `url` to the card as an NDEF record.

    The card is registered "in stock" without an activation code, so the same activation
    path serves both self-written cards and factory batches.
    """
    await hit(f"prepare:{user.id}", 60)
    token = card_token()
    db.add(Card(token=token, status="in_stock", chip_type="ntag215"))
    await db.commit()
    return schemas.CardPrepareOut(token=token, url=card_url(token))


@router.post("/activate", response_model=schemas.CardOut)
async def activate_card(
    data: schemas.CardActivateIn,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    player, space = await player_in_space(db, user, data.player_id, "admin")
    await hit(f"activate:{user.id}", 30)
    card = await db.scalar(select(Card).where(Card.token == data.token).with_for_update())
    if card is None:
        raise AppError("card_not_found", 404)
    if card.status == "active":
        raise AppError("card_already_linked", 409)
    if card.status == "blocked":
        raise AppError("card_blocked", 409)
    if card.status == "in_stock" and card.activation_code_hash is not None:
        code = (data.activation_code or "").strip().upper()
        if not code or sha256(code) != card.activation_code_hash:
            raise AppError("invalid_activation_code", 403)

    uid = data.uid.upper() if data.uid else None
    if uid:
        if card.uid and card.uid != uid:
            # The NDEF link was copied to another chip.
            raise AppError("card_uid_mismatch", 409)
        other = await ledger.card_by_uid(db, uid)
        if other is not None and other.id != card.id:
            raise AppError("card_uid_taken", 409)
        card.uid = uid

    seq = await ledger.bump_seq(db, space.id)
    card.status = "active"
    card.chip_type = data.chip_type
    card.space_id = space.id
    card.player_id = player.id
    card.label = data.label
    card.activated_at = now()
    card.blocked_at = None
    card.seq = seq
    player.seq = seq
    await db.commit()
    return card


async def _admin_card(db: AsyncSession, user: User, card_id: UUID) -> Card:
    card = await db.get(Card, card_id)
    if card is None or card.space_id is None:
        raise not_found("card_not_found")
    await membership(db, user, card.space_id, "admin")
    return card


@router.post("/{card_id}/block", response_model=schemas.CardOut)
async def block_card(
    card_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    card = await _admin_card(db, user, card_id)
    if card.status != "active":
        raise AppError("card_not_active", 409)
    card.seq = await ledger.bump_seq(db, card.space_id)
    card.status = "blocked"
    card.blocked_at = now()
    # A blocked card keeps its player so that earlier offline operations still resolve.
    await db.commit()
    return card


@router.post("/{card_id}/unlink", response_model=schemas.CardOut)
async def unlink_card(
    card_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    """Detach the card so it can be given to another child. Its history stays with the player."""
    card = await _admin_card(db, user, card_id)
    if card.status not in ("active", "blocked"):
        raise AppError("card_not_active", 409)
    card.seq = await ledger.bump_seq(db, card.space_id)
    card.status = "unlinked"
    card.player_id = None
    card.blocked_at = None
    await db.commit()
    return card


@router.post("/resolve", response_model=schemas.ResolveOut)
async def resolve_card(
    data: schemas.CardResolveIn,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    """A tap on the terminal: who is this, and what are their balances."""
    await membership(db, user, data.space_id, "operator")
    limit_key = f"resolve-fail:{user.id}"
    if await is_limited(limit_key, get_settings().card_resolve_fail_limit):
        raise AppError("rate_limited", 429)
    if not data.token and not data.uid:
        raise AppError("card_required", 422)
    try:
        player, card = await ledger.player_from_card(
            db, data.space_id, token=data.token, uid=data.uid
        )
    except AppError as e:
        if e.code == "card_not_found":
            await hit(limit_key, get_settings().card_resolve_fail_limit + 1)
        raise

    wallets = (
        await db.scalars(
            select(Wallet)
            .outerjoin(GameSession, GameSession.id == Wallet.session_id)
            .where(
                Wallet.player_id == player.id,
                (Wallet.kind == "persistent") | (GameSession.status != "finished"),
            )
        )
    ).all()
    in_session = None
    if data.session_id is not None:
        in_session = await db.get(SessionParticipant, (data.session_id, player.id)) is not None
    return schemas.ResolveOut(
        card=schemas.CardOut.model_validate(card),
        player=(await players_out(db, [player]))[0],
        wallets=[balance_out(w) for w in wallets],
        in_session=in_session,
    )
