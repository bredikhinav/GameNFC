from uuid import UUID

from fastapi import APIRouter, Depends, Response
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app import schemas
from app.db import get_db
from app.deps import current_user, membership
from app.errors import AppError, not_found
from app.models import (
    Allowance,
    Device,
    GameTemplate,
    Player,
    Product,
    Space,
    SpaceMember,
    TransferRequest,
    User,
    Wallet,
)
from app.services import ledger, operations
from app.services.views import space_out

router = APIRouter(prefix="/spaces", tags=["spaces"])


@router.get("", response_model=list[schemas.SpaceOut])
async def list_spaces(user: User = Depends(current_user), db: AsyncSession = Depends(get_db)):
    rows = await db.execute(
        select(Space, SpaceMember.role)
        .join(SpaceMember, SpaceMember.space_id == Space.id)
        .where(SpaceMember.user_id == user.id)
        .order_by(Space.created_at)
    )
    return [space_out(space, role) for space, role in rows]


@router.post("", response_model=schemas.SpaceOut, status_code=201)
async def create_space(
    data: schemas.SpaceIn, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    space = Space(**data.model_dump(), seq=1, updated_seq=1)
    if data.type == "organization":
        space.offline_spend_limit = 50
    db.add(space)
    await db.flush()
    db.add(SpaceMember(space_id=space.id, user_id=user.id, role="owner"))
    ledger.create_system_wallets(db, space.id, seq=1)
    await db.commit()
    return space_out(space, "owner")


@router.get("/{space_id}", response_model=schemas.SpaceOut)
async def get_space(
    space_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    space = await membership(db, user, space_id, "operator")
    role = await db.scalar(
        select(SpaceMember.role).where(
            SpaceMember.space_id == space_id, SpaceMember.user_id == user.id
        )
    )
    return space_out(space, role)


@router.patch("/{space_id}", response_model=schemas.SpaceOut)
async def update_space(
    space_id: UUID,
    data: schemas.SpacePatch,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    await membership(db, user, space_id, "admin")
    seq = await ledger.bump_seq(db, space_id)
    space = await db.get(Space, space_id, populate_existing=True)
    for key, value in data.model_dump(exclude_unset=True).items():
        if key in ("name", "currency_name", "currency_icon", "allow_negative") and value is None:
            continue
        setattr(space, key, value)
    space.updated_seq = seq
    await db.commit()
    return space_out(space)


@router.get("/{space_id}/summary")
async def summary(
    space_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    """Numbers for the organization overview screen."""
    await membership(db, user, space_id, "operator")
    total = await db.scalar(
        select(func.coalesce(func.sum(Wallet.balance), 0)).where(
            Wallet.space_id == space_id, Wallet.kind == "persistent"
        )
    )
    flagged = await db.scalar(
        select(func.count()).where(Wallet.space_id == space_id, Wallet.flagged.is_(True))
    )
    players = await db.scalar(
        select(func.count()).where(Player.space_id == space_id, Player.deleted_at.is_(None))
    )
    groups = await db.scalar(
        select(func.count(func.distinct(Player.group_name))).where(
            Player.space_id == space_id, Player.deleted_at.is_(None)
        )
    )
    pending = await db.scalar(
        select(func.count()).where(
            TransferRequest.space_id == space_id, TransferRequest.status == "pending"
        )
    )
    return {
        "players": players,
        "groups": groups,
        "total_balance": int(total or 0),
        "flagged_wallets": flagged,
        "pending_requests": pending,
    }


@router.post("/{space_id}/wallets/{wallet_id}/resolve-flag", status_code=204)
async def resolve_flag(
    space_id: UUID,
    wallet_id: UUID,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    await membership(db, user, space_id, "admin")
    seq = await ledger.bump_seq(db, space_id)
    wallet = await db.get(Wallet, wallet_id, populate_existing=True)
    if wallet is None or wallet.space_id != space_id:
        raise not_found("wallet_not_found")
    wallet.flagged = False
    wallet.flag_reason = None
    wallet.seq = seq
    await db.commit()
    return Response(status_code=204)


# --- Members and devices ----------------------------------------------------------


@router.get("/{space_id}/members", response_model=list[schemas.MemberOut])
async def list_members(
    space_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    await membership(db, user, space_id, "operator")
    rows = await db.execute(
        select(SpaceMember, User)
        .join(User, User.id == SpaceMember.user_id)
        .where(SpaceMember.space_id == space_id)
        .order_by(SpaceMember.created_at)
    )
    return [
        schemas.MemberOut(user_id=u.id, email=u.email, name=u.name, role=m.role) for m, u in rows
    ]


@router.post("/{space_id}/members", response_model=schemas.MemberOut, status_code=201)
async def add_member(
    space_id: UUID,
    data: schemas.MemberIn,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    await membership(db, user, space_id, "owner" if data.role == "admin" else "admin")
    invitee = await db.scalar(select(User).where(func.lower(User.email) == data.email.lower()))
    if invitee is None:
        # The operator registers in the app first, then the admin adds them.
        raise not_found("user_not_found")
    existing = await db.get(SpaceMember, (space_id, invitee.id))
    if existing is not None:
        raise AppError("already_member", 409)
    db.add(SpaceMember(space_id=space_id, user_id=invitee.id, role=data.role))
    await db.commit()
    return schemas.MemberOut(
        user_id=invitee.id, email=invitee.email, name=invitee.name, role=data.role
    )


@router.delete("/{space_id}/members/{user_id}", status_code=204)
async def remove_member(
    space_id: UUID,
    user_id: UUID,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    await membership(db, user, space_id, "admin")
    member = await db.get(SpaceMember, (space_id, user_id))
    if member is None:
        raise not_found("member_not_found")
    if member.role == "owner":
        raise AppError("cannot_remove_owner", 409)
    await db.delete(member)
    await db.commit()
    return Response(status_code=204)


@router.get("/{space_id}/devices", response_model=list[schemas.DeviceOut])
async def list_devices(
    space_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    await membership(db, user, space_id, "admin")
    return (
        await db.scalars(select(Device).where(Device.space_id == space_id).order_by(Device.name))
    ).all()


# --- Game templates ---------------------------------------------------------------


@router.get("/{space_id}/templates", response_model=list[schemas.TemplateOut])
async def list_templates(
    space_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    await membership(db, user, space_id, "operator")
    return await templates_for(db, space_id)


async def templates_for(db: AsyncSession, space_id: UUID) -> list[schemas.TemplateOut]:
    rows = await db.scalars(
        select(GameTemplate)
        .where(or_(GameTemplate.space_id.is_(None), GameTemplate.space_id == space_id))
        .order_by(GameTemplate.space_id.is_(None).desc(), GameTemplate.sort_order)
    )
    result = []
    for t in rows:
        out = schemas.TemplateOut.model_validate(t)
        out.builtin = t.space_id is None
        result.append(out)
    return result


# --- Recurring allowances ---------------------------------------------------------


@router.get("/{space_id}/allowances", response_model=list[schemas.AllowanceOut])
async def list_allowances(
    space_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    await membership(db, user, space_id, "operator")
    return (
        await db.scalars(
            select(Allowance)
            .where(Allowance.space_id == space_id, Allowance.active.is_(True))
            .order_by(Allowance.created_at)
        )
    ).all()


@router.post("/{space_id}/allowances", response_model=schemas.AllowanceOut, status_code=201)
async def create_allowance(
    space_id: UUID,
    data: schemas.AllowanceIn,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    await membership(db, user, space_id, "admin")
    if data.player_id is not None:
        await ledger.get_player(db, space_id, data.player_id)
    allowance = Allowance(space_id=space_id, created_by=user.id, **data.model_dump())
    db.add(allowance)
    await db.commit()
    return allowance


@router.delete("/{space_id}/allowances/{allowance_id}", status_code=204)
async def delete_allowance(
    space_id: UUID,
    allowance_id: UUID,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    await membership(db, user, space_id, "admin")
    allowance = await db.get(Allowance, allowance_id)
    if allowance is None or allowance.space_id != space_id:
        raise not_found("allowance_not_found")
    allowance.active = False
    await db.commit()
    return Response(status_code=204)


# --- Transfer requests from children ----------------------------------------------


@router.get("/{space_id}/transfer-requests", response_model=list[schemas.TransferRequestOut])
async def list_requests(
    space_id: UUID,
    status: str = "pending",
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    await membership(db, user, space_id, "admin")
    return (
        await db.scalars(
            select(TransferRequest)
            .where(TransferRequest.space_id == space_id, TransferRequest.status == status)
            .order_by(TransferRequest.created_at.desc())
            .limit(100)
        )
    ).all()


@router.post(
    "/{space_id}/transfer-requests/{request_id}/{decision}",
    response_model=schemas.TransferRequestOut,
)
async def decide_request(
    space_id: UUID,
    request_id: UUID,
    decision: str,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    if decision not in ("approve", "reject"):
        raise not_found()
    space = await membership(db, user, space_id, "admin")
    req = await operations.decide_request(db, space, request_id, user, decision == "approve")
    await db.commit()
    return req


# --- Shop (organizations) ---------------------------------------------------------


@router.get("/{space_id}/products", response_model=list[schemas.ProductOut])
async def list_products(
    space_id: UUID, user: User = Depends(current_user), db: AsyncSession = Depends(get_db)
):
    await membership(db, user, space_id, "operator")
    return (
        await db.scalars(
            select(Product)
            .where(Product.space_id == space_id, Product.active.is_(True))
            .order_by(Product.name)
        )
    ).all()


@router.post("/{space_id}/products", response_model=schemas.ProductOut, status_code=201)
async def create_product(
    space_id: UUID,
    data: schemas.ProductIn,
    user: User = Depends(current_user),
    db: AsyncSession = Depends(get_db),
):
    await membership(db, user, space_id, "admin")
    seq = await ledger.bump_seq(db, space_id)
    product = Product(space_id=space_id, seq=seq, **data.model_dump())
    db.add(product)
    await db.commit()
    return product
