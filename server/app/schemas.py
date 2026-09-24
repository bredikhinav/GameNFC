from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator

MAX_AMOUNT = 10_000_000
Amount = Field(gt=0, le=MAX_AMOUNT)


class ORM(BaseModel):
    model_config = ConfigDict(from_attributes=True)


# --- Auth --------------------------------------------------------------------------


class RegisterIn(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    name: str = Field(default="", max_length=80)
    locale: str = Field(default="ru", max_length=8)


class LoginIn(BaseModel):
    email: EmailStr
    password: str = Field(max_length=128)


class RefreshIn(BaseModel):
    refresh_token: str


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int


class EmailIn(BaseModel):
    email: EmailStr


class TokenIn(BaseModel):
    token: str


class ResetPasswordIn(BaseModel):
    token: str
    password: str = Field(min_length=8, max_length=128)


class PinIn(BaseModel):
    pin: str = Field(pattern=r"^\d{4,6}$")
    password: str = Field(max_length=128)


class PinOut(BaseModel):
    """Everything a device needs to verify the PIN offline (PBKDF2-HMAC-SHA256)."""

    salt: str
    hash: str
    iterations: int


class UserOut(ORM):
    id: UUID
    email: str
    name: str
    locale: str
    email_verified: bool
    pin: PinOut | None


# --- Spaces ------------------------------------------------------------------------


class SpaceSettings(BaseModel):
    allow_negative: bool | None = None
    daily_transfer_limit: int | None = Field(default=None, ge=0, le=MAX_AMOUNT)
    transfer_approval_threshold: int | None = Field(default=None, ge=0, le=MAX_AMOUNT)
    offline_spend_limit: int | None = Field(default=None, ge=0, le=MAX_AMOUNT)


class SpaceIn(BaseModel):
    type: Literal["family", "organization"] = "family"
    name: str = Field(min_length=1, max_length=80)
    currency_name: str = Field(default="монеты", min_length=1, max_length=32)
    currency_icon: str = Field(default="🪙", min_length=1, max_length=8)
    timezone: str = "Europe/Moscow"


class SpacePatch(SpaceSettings):
    name: str | None = Field(default=None, min_length=1, max_length=80)
    currency_name: str | None = Field(default=None, min_length=1, max_length=32)
    currency_icon: str | None = Field(default=None, min_length=1, max_length=8)
    # Explicit nulls clear a limit; omitted fields are left unchanged.


class SpaceOut(ORM):
    id: UUID
    type: str
    name: str
    currency_name: str
    currency_icon: str
    timezone: str
    allow_negative: bool
    daily_transfer_limit: int | None
    transfer_approval_threshold: int | None
    offline_spend_limit: int | None
    role: str | None = None


class MemberIn(BaseModel):
    email: EmailStr
    role: Literal["admin", "operator"] = "operator"


class MemberOut(BaseModel):
    user_id: UUID
    email: str
    name: str
    role: str


class DeviceOut(ORM):
    id: UUID
    user_id: UUID
    name: str
    last_sync_at: datetime | None
    pending_ops: int


# --- Players and cards -------------------------------------------------------------


class PlayerIn(BaseModel):
    name: str = Field(min_length=1, max_length=40)
    avatar: str = Field(default="default", max_length=32)
    birth_year: int | None = Field(default=None, ge=1990, le=2100)
    group_name: str | None = Field(default=None, max_length=40)
    consent: bool = Field(description="Legal representative consents to data processing")

    @field_validator("consent")
    @classmethod
    def _must_consent(cls, v: bool) -> bool:
        if not v:
            raise ValueError("consent is required")
        return v


class PlayerPatch(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=40)
    avatar: str | None = Field(default=None, max_length=32)
    birth_year: int | None = Field(default=None, ge=1990, le=2100)
    group_name: str | None = Field(default=None, max_length=40)


class CardBrief(ORM):
    id: UUID
    status: str
    chip_type: str
    label: str | None
    uid: str | None


class GoalIn(BaseModel):
    title: str = Field(min_length=1, max_length=60)
    target_amount: int = Amount


class GoalOut(ORM):
    title: str
    target_amount: int


class PlayerOut(ORM):
    id: UUID
    space_id: UUID
    name: str
    avatar: str
    birth_year: int | None
    group_name: str | None
    balance: int = 0
    wallet_id: UUID | None = None
    flagged: bool = False
    cards: list[CardBrief] = []
    linked_devices: int = 0
    goal: GoalOut | None = None
    deleted: bool = False


class CardPrepareOut(BaseModel):
    token: str
    url: str


class CardActivateIn(BaseModel):
    token: str = Field(min_length=6, max_length=32)
    uid: str | None = Field(default=None, pattern=r"^[0-9A-Fa-f]{8,20}$")
    chip_type: Literal["ntag213", "ntag215", "ntag216", "ntag424"] = "ntag215"
    activation_code: str | None = Field(default=None, max_length=32)
    player_id: UUID
    label: str | None = Field(default=None, max_length=40)


class CardResolveIn(BaseModel):
    space_id: UUID
    token: str | None = Field(default=None, max_length=32)
    uid: str | None = Field(default=None, pattern=r"^[0-9A-Fa-f]{8,20}$")
    session_id: UUID | None = None


class CardOut(ORM):
    id: UUID
    token: str
    uid: str | None
    chip_type: str
    status: str
    player_id: UUID | None
    label: str | None


class WalletBalance(BaseModel):
    wallet_id: UUID
    kind: str
    player_id: UUID | None = None
    session_id: UUID | None
    balance: int
    flagged: bool = False


class ResolveOut(BaseModel):
    card: CardOut
    player: PlayerOut
    wallets: list[WalletBalance]
    in_session: bool | None = None


# --- Sessions ----------------------------------------------------------------------


class QuickButton(BaseModel):
    label: str = Field(max_length=40)
    amount: int = Amount
    type: Literal["credit", "debit"] = "credit"


class TemplateOut(ORM):
    id: UUID
    name: str
    starting_capital: int
    quick_buttons: list[QuickButton]
    builtin: bool = False


class SessionIn(BaseModel):
    id: UUID
    name: str = Field(min_length=1, max_length=80)
    money_mode: Literal["reset", "persistent"] = "reset"
    starting_capital: int = Field(default=0, ge=0, le=MAX_AMOUNT)
    template_id: UUID | None = None
    quick_buttons: list[QuickButton] = []
    device_id: UUID | None = None
    created_at: datetime | None = None


class JoinIn(BaseModel):
    card_token: str | None = Field(default=None, max_length=32)
    card_uid: str | None = Field(default=None, pattern=r"^[0-9A-Fa-f]{8,20}$")
    player_id: UUID | None = None
    transaction_id: UUID = Field(description="Client id of the starting-capital transaction")
    joined_at: datetime | None = None
    device_id: UUID | None = None


class StatusIn(BaseModel):
    status: Literal["active", "paused"]
    at: datetime | None = None


class PrizeIn(BaseModel):
    player_id: UUID
    amount: int = Amount
    transaction_id: UUID


class FinishIn(BaseModel):
    prizes: list[PrizeIn] = []
    finished_at: datetime | None = None
    device_id: UUID | None = None


class Standing(BaseModel):
    place: int
    player_id: UUID
    name: str
    avatar: str
    balance: int
    net: int


class SessionOut(ORM):
    id: UUID
    space_id: UUID
    name: str
    money_mode: str
    starting_capital: int
    quick_buttons: list[QuickButton]
    status: str
    device_id: UUID | None
    started_at: datetime | None
    finished_at: datetime | None
    created_at: datetime


class SessionDetail(SessionOut):
    standings: list[Standing]


# --- Transactions ------------------------------------------------------------------


class TxIn(BaseModel):
    id: UUID
    type: Literal["credit", "debit", "transfer", "purchase", "reversal"]
    space_id: UUID
    session_id: UUID | None = None
    # Who: a tapped card (token from NDEF, or UID for a card without NDEF) or a player id.
    card_token: str | None = Field(default=None, max_length=32)
    card_uid: str | None = Field(default=None, pattern=r"^[0-9A-Fa-f]{8,20}$")
    player_id: UUID | None = None
    # Transfer receiver.
    to_card_token: str | None = Field(default=None, max_length=32)
    to_card_uid: str | None = Field(default=None, pattern=r"^[0-9A-Fa-f]{8,20}$")
    to_player_id: UUID | None = None
    amount: int | None = Field(default=None, gt=0, le=MAX_AMOUNT)
    product_id: UUID | None = None
    reverses_id: UUID | None = None
    comment: str | None = Field(default=None, max_length=140)
    device_id: UUID | None = None
    created_at: datetime | None = None


class TxOut(ORM):
    id: UUID
    space_id: UUID
    type: str
    from_wallet_id: UUID
    to_wallet_id: UUID
    amount: int
    session_id: UUID | None
    card_id: UUID | None
    reverses_id: UUID | None
    operator_id: UUID | None
    device_id: UUID | None
    comment: str | None
    created_at: datetime
    offline: bool
    seq: int


class PlayerBrief(BaseModel):
    id: UUID
    name: str
    avatar: str


class TxResult(BaseModel):
    transaction: TxOut
    balances: list[WalletBalance]
    player: PlayerBrief | None = None
    to_player: PlayerBrief | None = None
    duplicate: bool = False


class HistoryItem(BaseModel):
    id: UUID
    type: str
    amount: int
    direction: Literal["in", "out"]
    signed_amount: int
    session_id: UUID | None
    comment: str | None
    counterparty: PlayerBrief | None
    created_at: datetime
    reversed: bool = False


# --- Child mode --------------------------------------------------------------------


class DeviceLinkOut(BaseModel):
    code: str
    qr_payload: str
    expires_at: datetime


class ClaimIn(BaseModel):
    code: str = Field(min_length=6, max_length=16)
    device_name: str = Field(default="", max_length=80)


class ClaimOut(BaseModel):
    token: str
    player: PlayerBrief
    space_id: UUID


class ActiveGame(BaseModel):
    session_id: UUID
    name: str
    balance: int
    place: int
    players: int


class MeOut(BaseModel):
    player: PlayerBrief
    space: SpaceOut
    balance: int
    goal: GoalOut | None
    active_game: ActiveGame | None
    peers: list[PlayerBrief]
    transferred_today: int
    daily_transfer_limit: int | None
    transfer_approval_threshold: int | None
    recent: list[HistoryItem]
    pending_requests: int


class ChildTransferIn(BaseModel):
    id: UUID
    to_player_id: UUID | None = None
    to_card_token: str | None = Field(default=None, max_length=32)
    amount: int = Amount
    comment: str | None = Field(default=None, max_length=140)


class ChildTransferOut(BaseModel):
    status: Literal["done", "pending_approval"]
    balance: int
    transaction_id: UUID | None = None
    request_id: UUID | None = None


class TransferRequestOut(ORM):
    id: UUID
    from_player_id: UUID
    to_player_id: UUID
    amount: int
    comment: str | None
    status: str
    created_at: datetime


class AllowanceIn(BaseModel):
    player_id: UUID | None = None
    amount: int = Amount
    comment: str = Field(min_length=1, max_length=80)
    weekday: int = Field(ge=0, le=6)


class AllowanceOut(ORM):
    id: UUID
    player_id: UUID | None
    amount: int
    comment: str
    weekday: int
    active: bool


class ProductIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    emoji: str | None = Field(default=None, max_length=8)
    price: int = Amount
    stock: int | None = Field(default=None, ge=0)


class ProductOut(ORM):
    id: UUID
    name: str
    emoji: str | None
    price: int
    stock: int | None
    active: bool


# --- Sync --------------------------------------------------------------------------


class SyncOp(BaseModel):
    """One queued offline command. Every kind is idempotent by its own client id."""

    kind: Literal[
        "transaction", "session.create", "session.join", "session.status", "session.finish"
    ]
    session_id: UUID | None = None
    transaction: TxIn | None = None
    session: SessionIn | None = None
    join: JoinIn | None = None
    status: StatusIn | None = None
    finish: FinishIn | None = None


class SyncIn(BaseModel):
    space_id: UUID
    device_id: UUID
    device_name: str = Field(default="", max_length=80)
    cursor: int = Field(default=0, ge=0)
    ops: list[SyncOp] = Field(default=[], max_length=1000)


class SyncOpResult(BaseModel):
    index: int
    ok: bool
    error: str | None = None
    duplicate: bool = False


class ParticipantOut(ORM):
    session_id: UUID
    player_id: UUID
    wallet_id: UUID
    joined_at: datetime


class SyncChanges(BaseModel):
    space: SpaceOut | None
    players: list[PlayerOut]
    cards: list[CardOut]
    wallets: list[WalletBalance]
    sessions: list[SessionOut]
    participants: list[ParticipantOut]
    transactions: list[TxOut]
    templates: list[TemplateOut]
    products: list[ProductOut]


class SyncOut(BaseModel):
    results: list[SyncOpResult]
    cursor: int
    has_more: bool
    changes: SyncChanges
