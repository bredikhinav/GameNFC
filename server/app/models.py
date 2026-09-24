"""Database schema.

Money rules:
- Amounts are integers (no fractions).
- Every transaction moves `amount` from one wallet to another. The system wallets
  "bank" and "shop" of a space are the counterparties for credits and debits, so the
  sum of all wallet balances in a space is always zero.
- `wallets.balance` is a cache of the ledger; `reconcile` recomputes it.

Sync rules:
- Every space has a change counter `spaces.seq`. Each write inside a space bumps the
  counter (which also row-locks the space until commit) and stamps changed rows with
  the new value in their `seq` column. Clients pull "everything with seq > cursor".
"""

import uuid
from datetime import date, datetime

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    SmallInteger,
    String,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base

UUIDPK = UUID(as_uuid=True)


def _uuid_pk() -> Mapped[uuid.UUID]:
    return mapped_column(UUIDPK, primary_key=True, default=uuid.uuid4)


def _created_at() -> Mapped[datetime]:
    return mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)


# --- Adults and auth ---------------------------------------------------------------


class User(Base):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = _uuid_pk()
    email: Mapped[str] = mapped_column(String(254), unique=True, nullable=False)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    name: Mapped[str] = mapped_column(String(80), nullable=False, default="")
    locale: Mapped[str] = mapped_column(String(8), nullable=False, default="ru")
    # PBKDF2-SHA256 of the terminal PIN, verifiable offline by the user's own devices.
    pin_salt: Mapped[str | None] = mapped_column(String(64))
    pin_hash: Mapped[str | None] = mapped_column(String(128))
    pin_iterations: Mapped[int | None] = mapped_column(Integer)
    email_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _created_at()


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"

    id: Mapped[uuid.UUID] = _uuid_pk()
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True, nullable=False
    )
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _created_at()


class EmailToken(Base):
    __tablename__ = "email_tokens"
    __table_args__ = (CheckConstraint("purpose IN ('verify', 'reset')", name="purpose"),)

    id: Mapped[uuid.UUID] = _uuid_pk()
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True, nullable=False
    )
    purpose: Mapped[str] = mapped_column(String(16), nullable=False)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _created_at()


# --- Spaces ------------------------------------------------------------------------


class Space(Base):
    __tablename__ = "spaces"
    __table_args__ = (CheckConstraint("type IN ('family', 'organization')", name="type"),)

    id: Mapped[uuid.UUID] = _uuid_pk()
    type: Mapped[str] = mapped_column(String(16), nullable=False)
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    currency_name: Mapped[str] = mapped_column(String(32), nullable=False, default="монеты")
    currency_icon: Mapped[str] = mapped_column(String(8), nullable=False, default="🪙")
    timezone: Mapped[str] = mapped_column(String(64), nullable=False, default="Europe/Moscow")

    # Rules set by the owner.
    allow_negative: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    daily_transfer_limit: Mapped[int | None] = mapped_column(Integer)
    transfer_approval_threshold: Mapped[int | None] = mapped_column(Integer)
    offline_spend_limit: Mapped[int | None] = mapped_column(Integer)

    seq: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    updated_seq: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    created_at: Mapped[datetime] = _created_at()


class SpaceMember(Base):
    __tablename__ = "space_members"
    __table_args__ = (CheckConstraint("role IN ('owner', 'admin', 'operator')", name="role"),)

    space_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("spaces.id", ondelete="CASCADE"), primary_key=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True, index=True
    )
    role: Mapped[str] = mapped_column(String(16), nullable=False)
    created_at: Mapped[datetime] = _created_at()


class Device(Base):
    """A phone working as a terminal."""

    __tablename__ = "devices"

    id: Mapped[uuid.UUID] = mapped_column(UUIDPK, primary_key=True)  # generated by the app
    space_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("spaces.id", ondelete="CASCADE"), primary_key=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"), nullable=False)
    name: Mapped[str] = mapped_column(String(80), nullable=False, default="")
    last_sync_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    pending_ops: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    created_at: Mapped[datetime] = _created_at()


# --- Players and cards -------------------------------------------------------------


class Player(Base):
    __tablename__ = "players"

    id: Mapped[uuid.UUID] = _uuid_pk()
    space_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("spaces.id", ondelete="CASCADE"), index=True, nullable=False
    )
    name: Mapped[str] = mapped_column(String(40), nullable=False)
    avatar: Mapped[str] = mapped_column(String(32), nullable=False, default="default")
    birth_year: Mapped[int | None] = mapped_column(SmallInteger)
    group_name: Mapped[str | None] = mapped_column(String(40))  # e.g. camp squad
    consent_user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"), nullable=False)
    consent_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    seq: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    created_at: Mapped[datetime] = _created_at()


class PlayerDevice(Base):
    """A child's phone linked to a player via QR code."""

    __tablename__ = "player_devices"

    id: Mapped[uuid.UUID] = _uuid_pk()
    player_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("players.id", ondelete="CASCADE"), index=True, nullable=False
    )
    name: Mapped[str] = mapped_column(String(80), nullable=False, default="")
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _created_at()


class DeviceLink(Base):
    """One-time code shown as a QR code by the parent."""

    __tablename__ = "device_links"

    id: Mapped[uuid.UUID] = _uuid_pk()
    player_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("players.id", ondelete="CASCADE"), nullable=False
    )
    code_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    created_by: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _created_at()


class CardBatch(Base):
    __tablename__ = "card_batches"

    id: Mapped[uuid.UUID] = _uuid_pk()
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    chip_type: Mapped[str] = mapped_column(String(16), nullable=False)
    created_at: Mapped[datetime] = _created_at()


class Card(Base):
    __tablename__ = "cards"
    __table_args__ = (
        CheckConstraint("status IN ('in_stock', 'active', 'blocked', 'unlinked')", name="status"),
        CheckConstraint("chip_type IN ('ntag213', 'ntag215', 'ntag216', 'ntag424')", name="chip"),
        CheckConstraint(
            "(status IN ('active', 'blocked')) = (player_id IS NOT NULL)", name="active_has_player"
        ),
        Index("ix_cards_uid", "uid", unique=True, postgresql_where=text("uid IS NOT NULL")),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    token: Mapped[str] = mapped_column(String(32), unique=True, nullable=False)
    uid: Mapped[str | None] = mapped_column(String(32))  # hex, upper case
    chip_type: Mapped[str] = mapped_column(String(16), nullable=False, default="ntag215")
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    batch_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("card_batches.id"))
    activation_code_hash: Mapped[str | None] = mapped_column(String(64))
    # Set while the card is linked (or was linked last) to a player.
    space_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("spaces.id", ondelete="SET NULL"), index=True
    )
    player_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("players.id", ondelete="SET NULL"), index=True
    )
    label: Mapped[str | None] = mapped_column(String(40))
    activated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    blocked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    seq: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    created_at: Mapped[datetime] = _created_at()


# --- Money -------------------------------------------------------------------------


class GameTemplate(Base):
    __tablename__ = "game_templates"

    id: Mapped[uuid.UUID] = _uuid_pk()
    space_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("spaces.id", ondelete="CASCADE"), index=True
    )  # NULL = built-in template
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    starting_capital: Mapped[int] = mapped_column(Integer, nullable=False)
    # [{"label": "За круг", "amount": 200, "type": "credit"}]
    quick_buttons: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    created_at: Mapped[datetime] = _created_at()


class GameSession(Base):
    __tablename__ = "game_sessions"
    __table_args__ = (
        CheckConstraint("money_mode IN ('reset', 'persistent')", name="money_mode"),
        CheckConstraint("status IN ('lobby', 'active', 'paused', 'finished')", name="status"),
        CheckConstraint("starting_capital >= 0", name="capital"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUIDPK, primary_key=True)  # generated by the app
    space_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("spaces.id", ondelete="CASCADE"), index=True, nullable=False
    )
    template_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("game_templates.id"))
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    money_mode: Mapped[str] = mapped_column(String(16), nullable=False)
    starting_capital: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    quick_buttons: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    created_by: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"), nullable=False)
    device_id: Mapped[uuid.UUID | None] = mapped_column(UUIDPK)
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    seq: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class Wallet(Base):
    __tablename__ = "wallets"
    __table_args__ = (
        CheckConstraint("kind IN ('persistent', 'session', 'bank', 'shop')", name="kind"),
        CheckConstraint(
            "(kind IN ('persistent', 'session')) = (player_id IS NOT NULL)", name="owner"
        ),
        CheckConstraint("(kind = 'session') = (session_id IS NOT NULL)", name="session"),
        Index(
            "uq_wallet_persistent",
            "player_id",
            unique=True,
            postgresql_where=text("kind = 'persistent'"),
        ),
        Index(
            "uq_wallet_session",
            "player_id",
            "session_id",
            unique=True,
            postgresql_where=text("kind = 'session'"),
        ),
        Index(
            "uq_wallet_system",
            "space_id",
            "kind",
            unique=True,
            postgresql_where=text("kind IN ('bank', 'shop')"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUIDPK, primary_key=True)
    space_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("spaces.id", ondelete="CASCADE"), index=True, nullable=False
    )
    kind: Mapped[str] = mapped_column(String(16), nullable=False)
    player_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("players.id"))
    session_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("game_sessions.id"))
    balance: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    # Set when an offline sync pushed the balance below zero, etc.
    flagged: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    flag_reason: Mapped[str | None] = mapped_column(String(64))
    seq: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    created_at: Mapped[datetime] = _created_at()


class SessionParticipant(Base):
    __tablename__ = "session_participants"

    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("game_sessions.id", ondelete="CASCADE"), primary_key=True
    )
    player_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("players.id"), primary_key=True)
    wallet_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("wallets.id"), nullable=False)
    space_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("spaces.id"), nullable=False)
    joined_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    seq: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)


TX_TYPES = (
    "credit",
    "debit",
    "transfer",
    "purchase",
    "reversal",
    "session_start",
    "prize",
    "allowance",
)


class Transaction(Base):
    __tablename__ = "transactions"
    __table_args__ = (
        CheckConstraint("amount > 0", name="amount_positive"),
        CheckConstraint("from_wallet_id <> to_wallet_id", name="distinct_wallets"),
        CheckConstraint("type IN (" + ", ".join(f"'{t}'" for t in TX_TYPES) + ")", name="type"),
        CheckConstraint("(type = 'reversal') = (reverses_id IS NOT NULL)", name="reversal"),
        Index("ix_tx_space_seq", "space_id", "seq"),
        Index("ix_tx_from", "from_wallet_id", "created_at"),
        Index("ix_tx_to", "to_wallet_id", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUIDPK, primary_key=True)  # generated by the app
    space_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("spaces.id", ondelete="CASCADE"), nullable=False
    )
    type: Mapped[str] = mapped_column(String(16), nullable=False)
    from_wallet_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("wallets.id"), nullable=False)
    to_wallet_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("wallets.id"), nullable=False)
    amount: Mapped[int] = mapped_column(BigInteger, nullable=False)
    session_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("game_sessions.id"), index=True)
    card_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("cards.id"))
    reverses_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("transactions.id"), unique=True
    )
    operator_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id"))
    player_device_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("player_devices.id"))
    device_id: Mapped[uuid.UUID | None] = mapped_column(UUIDPK)
    comment: Mapped[str | None] = mapped_column(String(140))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    received_at: Mapped[datetime] = _created_at()
    offline: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    seq: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)


class TransferRequest(Base):
    """A child's transfer above the approval threshold, waiting for a parent."""

    __tablename__ = "transfer_requests"
    __table_args__ = (
        CheckConstraint("status IN ('pending', 'approved', 'rejected')", name="status"),
        CheckConstraint("amount > 0", name="amount_positive"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUIDPK, primary_key=True)  # generated by the app
    space_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("spaces.id", ondelete="CASCADE"), index=True, nullable=False
    )
    from_player_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("players.id"), nullable=False)
    to_player_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("players.id"), nullable=False)
    amount: Mapped[int] = mapped_column(BigInteger, nullable=False)
    comment: Mapped[str | None] = mapped_column(String(140))
    player_device_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("player_devices.id"))
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="pending")
    decided_by: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id"))
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    transaction_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("transactions.id"))
    seq: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    created_at: Mapped[datetime] = _created_at()


class SavingsGoal(Base):
    __tablename__ = "savings_goals"

    player_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("players.id", ondelete="CASCADE"), primary_key=True
    )
    title: Mapped[str] = mapped_column(String(60), nullable=False)
    target_amount: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = _created_at()


class Allowance(Base):
    """Recurring credit, e.g. "every Sunday +30 pocket coins"."""

    __tablename__ = "allowances"
    __table_args__ = (
        CheckConstraint("weekday BETWEEN 0 AND 6", name="weekday"),  # 0 = Monday
        CheckConstraint("amount > 0", name="amount_positive"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    space_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("spaces.id", ondelete="CASCADE"), index=True, nullable=False
    )
    player_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("players.id", ondelete="CASCADE")
    )  # NULL = every player of the space
    amount: Mapped[int] = mapped_column(Integer, nullable=False)
    comment: Mapped[str] = mapped_column(String(80), nullable=False)
    weekday: Mapped[int] = mapped_column(SmallInteger, nullable=False)
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    last_run_on: Mapped[date | None] = mapped_column(Date)
    created_by: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = _created_at()


class Product(Base):
    """Shop item of an organization (phase 3)."""

    __tablename__ = "products"
    __table_args__ = (CheckConstraint("price > 0", name="price_positive"),)

    id: Mapped[uuid.UUID] = _uuid_pk()
    space_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("spaces.id", ondelete="CASCADE"), index=True, nullable=False
    )
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    emoji: Mapped[str | None] = mapped_column(String(8))
    price: Mapped[int] = mapped_column(Integer, nullable=False)
    stock: Mapped[int | None] = mapped_column(Integer)
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    seq: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    created_at: Mapped[datetime] = _created_at()
