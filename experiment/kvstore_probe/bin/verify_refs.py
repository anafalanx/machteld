#!/usr/bin/env python3
"""Verify both kvstore references on all 62 cases."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

BIN = Path(__file__).resolve().parent
if str(BIN) not in sys.path: sys.path.insert(0, str(BIN))

from check import evaluate
from common import ARMS, EXP, HarnessError, REFS, RUNS, atomic_write_json, load_manifest, load_task, python_complete_tree, python_semantic_tree, sha256, verify_hash_map
from setup_runs import SERIOUS_RESULTS


def _runtimes(manifest_path: Path | None) -> tuple[Path, Path]:
    if manifest_path is None:
        return SERIOUS_RESULTS / "runtimes" / "python" / "python.exe", SERIOUS_RESULTS / "runtimes" / "machteld.exe"
    manifest = load_manifest(manifest_path)
    seal = manifest_path.with_suffix(".sha256")
    if not seal.is_file() or seal.read_text(encoding="ascii").strip() != sha256(manifest_path): raise HarnessError("manifest seal mismatch")
    verify_hash_map(EXP, manifest["apparatus_sha256"], "apparatus")
    python = EXP / manifest["python"]["frozen_executable"]
    python_root = EXP / manifest["python"]["frozen_root"]
    machteld = EXP / manifest["machteld"]["frozen_executable"]
    if not python.is_file() or sha256(python) != manifest["python"]["sha256"]:
        raise HarnessError("Python frozen runtime hash mismatch")
    if not machteld.is_file() or sha256(machteld) != manifest["machteld"]["sha256"]:
        raise HarnessError("machteld frozen runtime hash mismatch")
    for actual, expected, label in (
        (python_semantic_tree(python_root), manifest["python"]["semantic_tree"], "semantic"),
        (python_complete_tree(python_root), manifest["python"]["complete_tree"], "complete"),
    ):
        for field in ("sha256", "files", "bytes", "policy"):
            if actual.get(field) != expected.get(field):
                raise HarnessError(f"Python {label} runtime-tree {field} mismatch")
    return python, machteld


def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("--manifest", type=Path)
    parser.add_argument("--timeout", type=float, default=10.0); parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    try:
        task = load_task(); python, machteld = _runtimes(args.manifest)
        cases = task["visible_normalized"] + task["hidden_normalized"]
        rows = []; failed = False
        for arm, extension in ARMS.items():
            solution = REFS / arm / f"kvstore.{extension}"
            if not solution.is_file(): raise HarnessError(f"missing reference: {solution}")
            summary = evaluate(arm=arm, solution=solution, cases=cases, python_runtime=python,
                               machteld_runtime=machteld, timeout=args.timeout)
            failed |= not summary["all"]
            rows.append({"arm": arm, "reference": str(solution), "reference_sha256": sha256(solution),
                         "passed": summary["passed"], "total": summary["total"], "all": summary["all"],
                         "failures": [row for row in summary["cases"] if not row["passed"]]})
            print(f"{'PASS' if summary['all'] else 'FAIL'}  kvstore/{arm} {summary['passed']}/{summary['total']}")
        document = {"format": "machteld-kvstore-reference-verification-v1",
                    "python": {"path": str(python), "sha256": sha256(python)},
                    "machteld": {"path": str(machteld), "sha256": sha256(machteld)},
                    "rows": rows, "all": not failed}
        if args.json: atomic_write_json(args.json, document)
        print(f"{'PASS' if not failed else 'FAIL'}  2 references, {sum(r['passed'] for r in rows)}/{sum(r['total'] for r in rows)} cases")
        return 1 if failed else 0
    except (HarnessError, OSError, UnicodeError, json.JSONDecodeError) as exc: parser.error(str(exc))
    return 2


if __name__ == "__main__": raise SystemExit(main())
