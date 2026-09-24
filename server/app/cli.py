"""Admin commands: python -m app.cli <command> ...

generate-batch  create N warehouse cards with activation codes; writes a CSV for the
                card manufacturer (NDEF URL to encode) and for printing codes on packs
import-batch    import cards encoded elsewhere (CSV: token,uid[,activation_code])
run-allowances  post recurring allowances due today (run hourly from cron)
reconcile       compare wallet balances with the ledger (run nightly)
"""

import argparse
import asyncio
import csv
import logging
import sys

from sqlalchemy import select

from app.db import SessionLocal
from app.models import Card, CardBatch
from app.security import card_token, sha256, short_code
from app.services import jobs

CHIPS = ("ntag213", "ntag215", "ntag216", "ntag424")


def _url(token: str) -> str:
    from app.api.cards import card_url

    return card_url(token)


async def generate_batch(name: str, count: int, chip: str, out: str) -> None:
    async with SessionLocal() as db:
        batch = CardBatch(name=name, chip_type=chip)
        db.add(batch)
        await db.flush()
        rows = []
        for _ in range(count):
            token, code = card_token(), short_code(8)
            db.add(
                Card(
                    token=token,
                    status="in_stock",
                    chip_type=chip,
                    batch_id=batch.id,
                    activation_code_hash=sha256(code),
                )
            )
            rows.append((token, _url(token), code))
        await db.commit()
    with open(out, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["token", "ndef_url", "activation_code"])
        writer.writerows(rows)
    print(f"batch {batch.id}: {count} cards -> {out}")


async def import_batch(name: str, chip: str, path: str) -> None:
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    async with SessionLocal() as db:
        batch = CardBatch(name=name, chip_type=chip)
        db.add(batch)
        await db.flush()
        tokens = [r["token"].strip() for r in rows]
        taken = set(await db.scalars(select(Card.token).where(Card.token.in_(tokens))))
        added = 0
        for r in rows:
            token = r["token"].strip()
            if token in taken:
                continue
            code = (r.get("activation_code") or "").strip().upper()
            uid = (r.get("uid") or "").strip().upper() or None
            db.add(
                Card(
                    token=token,
                    uid=uid,
                    status="in_stock",
                    chip_type=chip,
                    batch_id=batch.id,
                    activation_code_hash=sha256(code) if code else None,
                )
            )
            added += 1
        await db.commit()
    print(f"batch {batch.id}: imported {added}, skipped {len(rows) - added} existing")


async def run_allowances() -> None:
    async with SessionLocal() as db:
        print(f"allowances posted: {await jobs.run_allowances(db)}")


async def reconcile(fix: bool) -> int:
    async with SessionLocal() as db:
        problems = await jobs.reconcile(db, fix=fix)
    print(f"problems: {problems}")
    return 1 if problems else 0


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    parser = argparse.ArgumentParser(prog="python -m app.cli")
    sub = parser.add_subparsers(dest="command", required=True)
    g = sub.add_parser("generate-batch")
    g.add_argument("--name", required=True)
    g.add_argument("--count", type=int, required=True)
    g.add_argument("--chip", choices=CHIPS, default="ntag215")
    g.add_argument("--out", required=True)
    i = sub.add_parser("import-batch")
    i.add_argument("--name", required=True)
    i.add_argument("--chip", choices=CHIPS, default="ntag215")
    i.add_argument("csv")
    sub.add_parser("run-allowances")
    r = sub.add_parser("reconcile")
    r.add_argument("--fix", action="store_true")
    args = parser.parse_args()

    if args.command == "generate-batch":
        asyncio.run(generate_batch(args.name, args.count, args.chip, args.out))
    elif args.command == "import-batch":
        asyncio.run(import_batch(args.name, args.chip, args.csv))
    elif args.command == "run-allowances":
        asyncio.run(run_allowances())
    else:
        sys.exit(asyncio.run(reconcile(args.fix)))


if __name__ == "__main__":
    main()
