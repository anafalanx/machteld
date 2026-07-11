#!/usr/bin/env python3
"""Validate every reference on every visible and hidden case."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

BIN = Path(__file__).resolve().parent
if str(BIN) not in sys.path:
    sys.path.insert(0, str(BIN))

from check import evaluate
from common import (
    ARMS,
    EXP,
    HarnessError,
    REFS,
    RUNS,
    discover_tasks,
    load_manifest,
    sha256,
    verify_hash_map,
)
from setup_runs import default_machteld


def _runtimes(manifest_path: Path | None, machteld_argument: Path | None) -> tuple[Path, Path]:
    if manifest_path is None:
        return Path(sys.executable).resolve(), (machteld_argument or default_machteld()).resolve()
    manifest = load_manifest(manifest_path)
    seal = manifest_path.with_suffix(".sha256")
    if not seal.is_file() or seal.read_text(encoding="ascii").strip() != sha256(manifest_path):
        raise HarnessError("manifest seal mismatch")
    verify_hash_map(EXP, manifest["apparatus_sha256"], "apparatus")
    python = EXP / manifest["python"]["frozen_executable"]
    machteld = EXP / manifest["machteld"]["frozen_executable"]
    for label, path, expected in (
        ("Python", python, manifest["python"]["sha256"]),
        ("machteld", machteld, manifest["machteld"]["sha256"]),
    ):
        if not path.is_file() or sha256(path) != expected:
            raise HarnessError(f"{label} frozen runtime hash mismatch: {path}")
    return python.resolve(), machteld.resolve()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--machteld", type=Path)
    parser.add_argument("--task", action="append", dest="tasks")
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    try:
        tasks = discover_tasks()
        if args.tasks:
            wanted = set(args.tasks)
            unknown = wanted - {task["id"] for task in tasks}
            if unknown:
                raise HarnessError("unknown task(s): " + ", ".join(sorted(unknown)))
            tasks = [task for task in tasks if task["id"] in wanted]
        python, machteld = _runtimes(args.manifest, args.machteld)
        if not python.is_file() or not machteld.is_file():
            raise HarnessError("reference runtime is missing")
        rows: list[dict] = []
        failed = False
        for task in tasks:
            cases = task["visible_normalized"] + task["hidden_normalized"]
            for arm, extension in ARMS.items():
                solution = REFS / arm / f"{task['id']}.{extension}"
                if not solution.is_file():
                    raise HarnessError(f"missing reference: {solution}")
                summary = evaluate(
                    arm=arm,
                    solution=solution,
                    cases=cases,
                    fn=task["fn"],
                    outputs=task["out"],
                    python_runtime=python,
                    machteld_runtime=machteld,
                    timeout=args.timeout,
                )
                failed |= not summary["all"]
                rows.append(
                    {
                        "task": task["id"],
                        "arm": arm,
                        "reference": str(solution),
                        "reference_sha256": sha256(solution),
                        "passed": summary["passed"],
                        "total": summary["total"],
                        "all": summary["all"],
                        "failures": [row for row in summary["cases"] if not row["passed"]],
                    }
                )
                print(
                    f"{'PASS' if summary['all'] else 'FAIL'}  {task['id']}/{arm} "
                    f"{summary['passed']}/{summary['total']}"
                )
        document = {
            "format": "machteld-serious-reference-verification-v1",
            "python": {"path": str(python), "sha256": sha256(python)},
            "machteld": {"path": str(machteld), "sha256": sha256(machteld)},
            "rows": rows,
            "all": not failed,
        }
        if args.json:
            args.json.write_text(
                json.dumps(document, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
                newline="\n",
            )
        print(
            f"{'PASS' if not failed else 'FAIL'}  {len(rows)} references, "
            f"{sum(row['passed'] for row in rows)}/{sum(row['total'] for row in rows)} cases"
        )
        return 1 if failed else 0
    except (HarnessError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
