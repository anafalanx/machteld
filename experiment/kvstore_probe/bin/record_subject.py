#!/usr/bin/env python3
"""Atomically start, finish, and validate unique kvstore subject metadata."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import tempfile
from typing import Any

BIN = Path(__file__).resolve().parent
if str(BIN) not in sys.path:
    sys.path.insert(0, str(BIN))

from common import EXP, HarnessError, RUNS, load_manifest, sha256


FIELDS = ("cell", "wave", "agent_id", "model_family", "started_utc", "ended_utc",
          "status", "valid", "exclusion", "note")
STATUSES = {"completed", "timed_out", "abnormal", "infrastructure_error", "contaminated"}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _timestamp(value: Any, field: str, optional: bool = False) -> None:
    if optional and value is None:
        return
    if type(value) is not str or not value.endswith("Z"):
        raise HarnessError(f"{field} must be an ISO-8601 UTC timestamp ending in Z")
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as exc:
        raise HarnessError(f"invalid {field}: {value!r}") from exc


def read_rows(path: Path, cells: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
    rows: dict[str, dict[str, Any]] = {}
    if not path.exists():
        return rows
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            raise HarnessError(f"blank metadata line {number}")
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            raise HarnessError(f"invalid metadata line {number}: {exc}") from exc
        if type(row) is not dict or set(row) != set(FIELDS):
            raise HarnessError(f"metadata line {number} has wrong fields")
        cell = row["cell"]
        if cell not in cells or cell in rows or row["wave"] != cells[cell]["wave"]:
            raise HarnessError(f"unknown, duplicate, or wave-mismatched cell on line {number}")
        rows[cell] = row
    return rows


def validate_row(row: dict[str, Any], finished: bool) -> None:
    if type(row["agent_id"]) is not str or not row["agent_id"].strip():
        raise HarnessError("agent_id must be nonempty")
    if type(row["model_family"]) is not str or not row["model_family"].strip():
        raise HarnessError("model_family must be nonempty")
    _timestamp(row["started_utc"], "started_utc")
    _timestamp(row["ended_utc"], "ended_utc", optional=not finished)
    if finished:
        if row["status"] not in STATUSES or type(row["valid"]) is not bool:
            raise HarnessError("invalid status or valid flag")
        if row["valid"] and (row["status"] != "completed" or row["exclusion"] is not None):
            raise HarnessError("valid=true requires completed and no exclusion")
        if not row["valid"] and (type(row["exclusion"]) is not str or not row["exclusion"]):
            raise HarnessError("invalid subject requires an exclusion reason")
        if datetime.fromisoformat(row["ended_utc"][:-1] + "+00:00") < datetime.fromisoformat(row["started_utc"][:-1] + "+00:00"):
            raise HarnessError("ended_utc precedes started_utc")
    elif any(row[field] is not None for field in ("ended_utc", "status", "valid", "exclusion")):
        raise HarnessError("started row has completion fields")
    if type(row["note"]) is not str:
        raise HarnessError("note must be a string")


def _write(path: Path, rows: dict[str, dict[str, Any]], order: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            for cell in order:
                if cell in rows:
                    stream.write(json.dumps(rows[cell], ensure_ascii=False, separators=(",", ":")) + "\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _boolean(text: str) -> bool:
    if text.lower() == "true": return True
    if text.lower() == "false": return False
    raise argparse.ArgumentTypeError("expected true or false")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=RUNS / "manifest.json")
    parser.add_argument("--metadata", type=Path, default=EXP / "subject-metadata.jsonl")
    commands = parser.add_subparsers(dest="command", required=True)
    start = commands.add_parser("start")
    start.add_argument("--cell", required=True); start.add_argument("--agent-id", required=True)
    start.add_argument("--model-family", required=True); start.add_argument("--started-utc"); start.add_argument("--note", default="")
    finish = commands.add_parser("finish")
    finish.add_argument("--cell", required=True); finish.add_argument("--status", choices=sorted(STATUSES), required=True)
    finish.add_argument("--valid", type=_boolean, required=True); finish.add_argument("--exclusion")
    finish.add_argument("--ended-utc"); finish.add_argument("--note")
    complete = commands.add_parser("complete")
    complete.add_argument("--cell", required=True); complete.add_argument("--agent-id", required=True)
    complete.add_argument("--model-family", required=True); complete.add_argument("--started-utc", required=True)
    complete.add_argument("--ended-utc"); complete.add_argument("--status", choices=sorted(STATUSES), default="completed")
    complete.add_argument("--valid", type=_boolean, default=True); complete.add_argument("--exclusion"); complete.add_argument("--note", default="")
    commands.add_parser("validate")
    args = parser.parse_args()

    lock = args.metadata.with_suffix(args.metadata.suffix + ".lock")
    descriptor: int | None = None
    acquired = False
    try:
        manifest = load_manifest(args.manifest)
        seal = args.manifest.with_suffix(".sha256")
        if not seal.is_file() or seal.read_text(encoding="ascii").strip() != sha256(args.manifest):
            raise HarnessError("manifest seal mismatch")
        cells = {cell["cell"]: cell for cell in manifest["cells"]}
        order = [cell["cell"] for cell in manifest["cells"]]
        descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        acquired = True; os.close(descriptor); descriptor = None
        rows = read_rows(args.metadata, cells)
        if args.command == "validate":
            for row in rows.values(): validate_row(row, row["ended_utc"] is not None)
            agent_ids = [row["agent_id"] for row in rows.values()]
            if len(set(agent_ids)) != len(agent_ids):
                raise HarnessError("agent_id reused; every cell requires a fresh subject")
            print(f"PASS  {len(rows)} unique metadata row(s)")
            return 0
        if args.cell not in cells:
            raise HarnessError(f"unknown cell: {args.cell}")
        if args.command == "start":
            if args.cell in rows: raise HarnessError(f"metadata row already exists: {args.cell}")
            row = {"cell": args.cell, "wave": cells[args.cell]["wave"], "agent_id": args.agent_id,
                   "model_family": args.model_family, "started_utc": args.started_utc or utc_now(),
                   "ended_utc": None, "status": None, "valid": None, "exclusion": None, "note": args.note}
            validate_row(row, False)
        elif args.command == "finish":
            if args.cell not in rows or rows[args.cell]["ended_utc"] is not None:
                raise HarnessError("cannot finish missing or already-finished row")
            row = dict(rows[args.cell]); row.update({"ended_utc": args.ended_utc or utc_now(), "status": args.status,
                                                    "valid": args.valid, "exclusion": args.exclusion,
                                                    "note": row["note"] if args.note is None else args.note})
            validate_row(row, True)
        else:
            if args.cell in rows: raise HarnessError(f"metadata row already exists: {args.cell}")
            row = {"cell": args.cell, "wave": cells[args.cell]["wave"], "agent_id": args.agent_id,
                   "model_family": args.model_family, "started_utc": args.started_utc,
                   "ended_utc": args.ended_utc or utc_now(), "status": args.status, "valid": args.valid,
                   "exclusion": args.exclusion, "note": args.note}
            validate_row(row, True)
        if any(other["agent_id"] == row["agent_id"] for key, other in rows.items() if key != args.cell):
            raise HarnessError("agent_id reused; every cell requires a fresh subject")
        rows[args.cell] = row; _write(args.metadata, rows, order)
        print(f"recorded {args.command}: {args.cell} (wave {row['wave']})")
        return 0
    except (HarnessError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    finally:
        if descriptor is not None: os.close(descriptor)
        if acquired: lock.unlink(missing_ok=True)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
