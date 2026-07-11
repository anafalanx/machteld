#!/usr/bin/env python3
"""Integrity-check, archive, then hidden-grade all six kvstore cells."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import statistics
import sys
from typing import Any

BIN = Path(__file__).resolve().parent
if str(BIN) not in sys.path:
    sys.path.insert(0, str(BIN))

from check import evaluate
from common import (
    ARMS, ATTEMPTS, DESIGN, EXP, HarnessError, HIDDEN_CASES,
    MAX_VISIBLE_CHECKS, RESULT_FORMAT, RESULTS, RUNS, SEED,
    TRIALS_PER_ARM, VISIBLE_CASES, apparatus_hashes, atomic_write_json,
    load_manifest, load_task, python_complete_tree, python_semantic_tree, remove_tree, sha256,
    verify_hash_map,
)
from record_subject import read_rows, validate_row


def _verify_manifest(path: Path, manifest: dict[str, Any]) -> None:
    seal = path.with_suffix(".sha256")
    if not seal.is_file() or seal.read_text(encoding="ascii").strip() != sha256(path):
        raise HarnessError("manifest seal mismatch")
    if manifest.get("seed") != SEED or manifest.get("design") != DESIGN:
        raise HarnessError("manifest seed/design mismatch")
    if manifest.get("trials_per_arm") != TRIALS_PER_ARM or manifest.get("max_visible_checks") != MAX_VISIBLE_CHECKS:
        raise HarnessError("manifest replication/check-cap mismatch")
    if manifest.get("visible_cases") != VISIBLE_CASES or manifest.get("hidden_cases") != HIDDEN_CASES:
        raise HarnessError("manifest case-count mismatch")
    cells = manifest.get("cells")
    if type(cells) is not list or len(cells) != 6:
        raise HarnessError("manifest must contain exactly six cells")
    names = [cell.get("cell") for cell in cells]
    if any(type(name) is not str for name in names) or len(set(names)) != 6:
        raise HarnessError("cell ids missing or duplicated")
    for arm in ARMS:
        selected = [cell for cell in cells if cell.get("arm") == arm]
        if len(selected) != 3 or {cell.get("trial") for cell in selected} != {1, 2, 3}:
            raise HarnessError(f"replication mismatch: {arm}")
    waves = manifest.get("waves")
    if type(waves) is not list or len(waves) != 2:
        raise HarnessError("manifest must contain two waves")
    for number, wave in enumerate(waves, 1):
        if wave.get("wave") != number or len(wave.get("cells", [])) != 3 or set(wave.get("arms", [])) != set(ARMS):
            raise HarnessError(f"wave {number} is invalid")
        selected = [cell for cell in cells if cell["cell"] in wave["cells"]]
        if len(selected) != 3 or {cell["wave"] for cell in selected} != {number}:
            raise HarnessError(f"wave {number} disagrees with cell rows")
    for position in (1, 2, 3):
        pair = [cell["arm"] for cell in cells if cell.get("wave_position") == position]
        if len(pair) != 2 or pair[0] == pair[1]:
            raise HarnessError(f"wave position {position} is not arm-complementary")


def _verify_runtimes(manifest: dict[str, Any], root: Path = EXP) -> tuple[Path, Path]:
    python = (root / manifest["python"]["frozen_executable"]).resolve()
    machteld = (root / manifest["machteld"]["frozen_executable"]).resolve()
    for label, path, expected in (("Python", python, manifest["python"]["sha256"]),
                                  ("machteld", machteld, manifest["machteld"]["sha256"])):
        if not path.is_file() or sha256(path) != expected:
            raise HarnessError(f"{label} frozen runtime hash mismatch")
    python_root = (root / manifest["python"]["frozen_root"]).resolve()
    tree = python_semantic_tree(python_root)
    for field in ("sha256", "files", "bytes", "policy"):
        if tree.get(field) != manifest["python"]["semantic_tree"].get(field):
            raise HarnessError(f"Python runtime-tree {field} mismatch")
    complete = python_complete_tree(python_root)
    for field in ("sha256", "files", "bytes", "policy"):
        if complete.get(field) != manifest["python"]["complete_tree"].get(field):
            raise HarnessError(f"Python complete runtime-tree {field} mismatch")
    return python, machteld


def _metadata(path: Path, cells: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    cell_map = {cell["cell"]: cell for cell in cells}
    rows = read_rows(path, cell_map)
    missing = set(cell_map) - rows.keys()
    if missing:
        raise HarnessError(f"metadata missing {len(missing)} cell(s), first {sorted(missing)[0]}")
    for row in rows.values():
        validate_row(row, True)
    ids = [row["agent_id"] for row in rows.values()]
    if len(set(ids)) != 6:
        raise HarnessError("every cell requires a unique fresh agent_id")
    families = {row["model_family"] for row in rows.values()}
    if len(families) != 1:
        raise HarnessError("all cells must use one model family")
    return rows


def _verify_cell(cell: dict[str, Any], root: Path = EXP) -> tuple[Path, Path]:
    directory = (root / cell["directory"]).resolve()
    expected_parent = (root / "runs").resolve()
    if directory.parent != expected_parent or not directory.is_dir():
        raise HarnessError(f"invalid cell directory: {directory}")
    allowed = set(cell["public_sha256"]) | {cell["solution"]}
    actual = {path.name for path in directory.iterdir()}
    if actual != allowed:
        raise HarnessError(f"unexpected/missing cell files: {cell['cell']} {sorted(actual ^ allowed)}")
    for name, expected in cell["public_sha256"].items():
        path = directory / name
        if not path.is_file() or sha256(path) != expected:
            raise HarnessError(f"public artifact hash mismatch: {path}")
    solution = directory / cell["solution"]
    if not solution.is_file():
        raise HarnessError(f"missing solution: {solution}")
    return directory, solution


def _read_attempts(cell: dict[str, Any], root: Path = EXP) -> list[dict[str, Any]]:
    directory = root / cell["attempt_directory"]
    if not directory.exists():
        return []
    if not directory.is_dir():
        raise HarnessError(f"attempt path is not a directory: {directory}")
    invocations = sorted(path for path in directory.glob("invocation-*") if path.is_dir())
    allowed_top = {path.name for path in invocations} | {"attempts.jsonl"}
    actual_top = {path.name for path in directory.iterdir()}
    if actual_top - allowed_top:
        raise HarnessError(f"unexpected attempt artifacts: {cell['cell']}")
    records: list[dict[str, Any]] = []
    for number, invocation in enumerate(invocations, 1):
        if invocation.name != f"invocation-{number:03d}":
            raise HarnessError(f"nonconsecutive invocation directory: {invocation}")
        record_path = invocation / "record.json"
        snapshot = invocation / ("solution" + Path(cell["solution"]).suffix)
        if {path.name for path in invocation.iterdir()} != {"record.json", snapshot.name}:
            raise HarnessError(f"unexpected invocation contents: {invocation}")
        try:
            record = json.loads(record_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise HarnessError(f"invalid attempt record: {record_path}: {exc}") from exc
        if record.get("attempt") != number or record.get("cell") != cell["cell"] or record.get("snapshot") != snapshot.name:
            raise HarnessError(f"attempt identity mismatch: {record_path}")
        if not snapshot.is_file() or record.get("snapshot_sha256") != sha256(snapshot) or record.get("snapshot_bytes") != snapshot.stat().st_size:
            raise HarnessError(f"attempt snapshot hash/size mismatch: {snapshot}")
        if number <= MAX_VISIBLE_CHECKS:
            if record.get("over_limit") is not False:
                raise HarnessError(f"allowed invocation marked over-limit: {record_path}")
            if record.get("executed") is not True and not record.get("infrastructure_error"):
                raise HarnessError(f"unexecuted invocation lacks infrastructure error: {record_path}")
        elif record.get("executed") is not False or record.get("over_limit") is not True:
            raise HarnessError(f"over-limit invocation executed: {record_path}")
        records.append({**record, "snapshot_path": str(snapshot)})
    log = directory / "attempts.jsonl"
    if records and not log.is_file():
        raise HarnessError(f"missing attempt log: {log}")
    if log.is_file():
        logged = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines() if line]
        comparable = [{key: value for key, value in row.items() if key != "snapshot_path"} for row in records]
        if logged != comparable:
            raise HarnessError(f"attempt JSONL/records mismatch: {cell['cell']}")
    return records


def _state(directory: Path) -> dict[str, tuple[int, str]]:
    if not directory.exists(): return {}
    return {path.relative_to(directory).as_posix(): (path.stat().st_size, sha256(path))
            for path in directory.rglob("*") if path.is_file()}


def _source(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    try:
        text = data.decode("utf-8", errors="strict"); utf8 = True
    except UnicodeDecodeError:
        text = data.decode("utf-8", errors="replace"); utf8 = False
    return {"sha256": sha256(path), "bytes": len(data), "utf8": utf8,
            "nonblank_lines": sum(bool(line.strip()) for line in text.splitlines())}


def _archive(staging: Path, manifest_path: Path, metadata_path: Path, manifest: dict[str, Any]) -> None:
    staging.mkdir()
    shutil.copy2(manifest_path, staging / "run-manifest.json")
    shutil.copy2(manifest_path.with_suffix(".sha256"), staging / "run-manifest.sha256")
    shutil.copy2(metadata_path, staging / "subject-metadata.jsonl")
    template = EXP / manifest["metadata_template"]["path"]
    shutil.copy2(template, staging / "subject-metadata-template.jsonl")
    apparatus = staging / "apparatus"
    for relative in manifest["apparatus_sha256"]:
        source = EXP / relative; target = apparatus / relative
        target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source, target)
    cells_root = staging / "cells"
    for cell in manifest["cells"]:
        shutil.copytree(EXP / cell["directory"], cells_root / cell["cell"])
    attempts_root = staging / "attempts"; attempts_root.mkdir()
    for cell in manifest["cells"]:
        source = EXP / cell["attempt_directory"]
        if source.is_dir(): shutil.copytree(source, attempts_root / cell["cell"])
    shutil.copytree(RUNS / "_frozen", staging / "runtimes")
    atomic_write_json(staging / "runtime-lock.json", {"python": manifest["python"], "machteld": manifest["machteld"],
                                                       "provenance": manifest["runtime_provenance"]})


def _archived_runtimes(staging: Path, manifest: dict[str, Any]) -> tuple[Path, Path]:
    source_root = (RUNS / "_frozen").resolve()
    source_python = (EXP / manifest["python"]["frozen_executable"]).resolve()
    source_python_root = (EXP / manifest["python"]["frozen_root"]).resolve()
    source_machteld = (EXP / manifest["machteld"]["frozen_executable"]).resolve()
    python = staging / "runtimes" / source_python.relative_to(source_root)
    python_root = staging / "runtimes" / source_python_root.relative_to(source_root)
    machteld = staging / "runtimes" / source_machteld.relative_to(source_root)
    if sha256(python) != manifest["python"]["sha256"] or sha256(machteld) != manifest["machteld"]["sha256"]:
        raise HarnessError("archived runtime hash mismatch")
    tree = python_semantic_tree(python_root)
    for field in ("sha256", "files", "bytes", "policy"):
        if tree[field] != manifest["python"]["semantic_tree"][field]:
            raise HarnessError(f"archived Python runtime-tree {field} mismatch")
    complete = python_complete_tree(python_root)
    for field in ("sha256", "files", "bytes", "policy"):
        if complete[field] != manifest["python"]["complete_tree"][field]:
            raise HarnessError(f"archived Python complete runtime-tree {field} mismatch")
    return python, machteld


def _grade_one(cell: dict[str, Any], metadata: dict[str, Any], task: dict[str, Any],
               python: Path, machteld: Path, staging: Path, timeout: float) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    solution = staging / "cells" / cell["cell"] / cell["solution"]
    attempt_root = staging / "attempts" / cell["cell"]
    cell_before = _state(solution.parent); attempts_before = _state(attempt_root)
    final_hash = sha256(solution)
    final_hidden = evaluate(arm=cell["arm"], solution=solution, cases=task["hidden_normalized"],
                            python_runtime=python, machteld_runtime=machteld, timeout=timeout)
    attempts = _read_attempts({**cell, "attempt_directory": f"attempts/{cell['cell']}"}, staging)
    attempt_rows: list[dict[str, Any]] = []
    first_green: int | None = None
    deviations: list[str] = []
    if metadata["valid"]:
        broken = [row for row in attempts if row["attempt"] <= MAX_VISIBLE_CHECKS and row.get("executed") is not True]
        if broken:
            raise HarnessError(f"valid subject has failed official checker infrastructure: {cell['cell']}")
    for record in attempts:
        snapshot = Path(record["snapshot_path"])
        visible = evaluate(arm=cell["arm"], solution=snapshot, cases=task["visible_normalized"],
                           python_runtime=python, machteld_runtime=machteld, timeout=timeout)
        hidden = evaluate(arm=cell["arm"], solution=snapshot, cases=task["hidden_normalized"],
                          python_runtime=python, machteld_runtime=machteld, timeout=timeout)
        if sha256(snapshot) != record["snapshot_sha256"]:
            raise HarnessError(f"candidate mutated attempt snapshot: {snapshot}")
        if record.get("executed"):
            logged = record.get("summary")
            if type(logged) is not dict or any(logged.get(field) != visible.get(field) for field in ("passed", "total", "all")):
                raise HarnessError(f"visible checker replay mismatch: {cell['cell']} #{record['attempt']}")
            if visible["all"] and first_green is None: first_green = record["attempt"]
        if record.get("over_limit"): deviations.append("attempted_more_than_8_visible_checks")
        attempt_rows.append({"cell": cell["cell"], "arm": cell["arm"], "trial": cell["trial"],
                             "attempt": record["attempt"], "executed": record.get("executed"),
                             "over_limit": record.get("over_limit"), "infrastructure_error": record.get("infrastructure_error"),
                             "snapshot_sha256": record["snapshot_sha256"], "snapshot_bytes": record["snapshot_bytes"],
                             "visible": visible, "hidden": hidden})
    if final_hidden["all"] and first_green is None: deviations.append("hidden_correct_without_visible_green")
    if sha256(solution) != final_hash or _state(solution.parent) != cell_before or _state(attempt_root) != attempts_before:
        raise HarnessError(f"candidate mutated archived trial artifacts: {cell['cell']}")
    row = {"cell": cell["cell"], "task": "kvstore", "arm": cell["arm"], "trial": cell["trial"],
           "wave": cell["wave"], "status": metadata["status"], "valid": metadata["valid"],
           "exclusion": metadata["exclusion"], "model_family": metadata["model_family"],
           "agent_id": metadata["agent_id"], "started_utc": metadata["started_utc"],
           "ended_utc": metadata["ended_utc"], "metadata_note": metadata["note"],
           "hidden": final_hidden, "blind_hidden_solve": metadata["valid"] is True and final_hidden["all"],
           "visible_checks": sum(record.get("executed") is True for record in attempts),
           "first_green": first_green, "one_check_solve": final_hidden["all"] and first_green == 1,
           "attempt_snapshots": len(attempts), "protocol_deviations": sorted(set(deviations)),
           "source": _source(solution)}
    return row, attempt_rows


def _summary(rows: list[dict[str, Any]]) -> dict[str, Any]:
    by_arm: dict[str, Any] = {}
    for arm in ARMS:
        assigned = [row for row in rows if row["arm"] == arm]
        valid = [row for row in assigned if row["valid"]]
        solved = [row for row in valid if row["hidden"]["all"]]
        def median(field: str) -> float | None:
            values = [row[field] for row in solved]
            return statistics.median(values) if values else None
        by_arm[arm] = {"assigned": len(assigned), "valid": len(valid), "solved": len(solved),
                       "solve_fraction": f"{len(solved)}/{len(valid)}" if valid else "0/0",
                       "hidden_cases_passed": sum(row["hidden"]["passed"] for row in valid),
                       "hidden_cases_total": sum(row["hidden"]["total"] for row in valid),
                       "one_check_solves": sum(row["one_check_solve"] for row in solved),
                       "median_checks_solved": median("visible_checks"),
                       "median_bytes_solved": statistics.median([row["source"]["bytes"] for row in solved]) if solved else None,
                       "median_nonblank_lines_solved": statistics.median([row["source"]["nonblank_lines"] for row in solved]) if solved else None}
    return {"format": RESULT_FORMAT, "design": DESIGN, "cells": 6,
            "valid_cells": sum(row["valid"] for row in rows), "invalid_cells": sum(not row["valid"] for row in rows),
            "interpretation": "descriptive supplement only; no equivalence or superiority classifier",
            "by_arm": by_arm,
            "exact_rows": [{"cell": row["cell"], "arm": row["arm"], "trial": row["trial"],
                            "valid": row["valid"], "solved": row["blind_hidden_solve"],
                            "hidden": f"{row['hidden']['passed']}/{row['hidden']['total']}",
                            "checks": row["visible_checks"], "bytes": row["source"]["bytes"],
                            "nonblank_lines": row["source"]["nonblank_lines"]} for row in rows]}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=RUNS / "manifest.json")
    parser.add_argument("--metadata", type=Path, default=EXP / "subject-metadata.jsonl")
    parser.add_argument("--results", type=Path, default=RESULTS)
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()
    staging = args.results.parent / f".{args.results.name}.staging-{os.getpid()}"
    try:
        if args.timeout <= 0: raise HarnessError("timeout must be positive")
        if args.results.exists() and any(path.name != ".gitkeep" for path in args.results.iterdir()):
            raise HarnessError("results already exist; grading never overwrites")
        if staging.exists(): raise HarnessError(f"staging already exists: {staging}")
        manifest = load_manifest(args.manifest); _verify_manifest(args.manifest, manifest)
        current = apparatus_hashes()
        if set(current) != set(manifest["apparatus_sha256"]):
            raise HarnessError("apparatus inventory changed after setup")
        verify_hash_map(EXP, manifest["apparatus_sha256"], "apparatus")
        template = EXP / manifest["metadata_template"]["path"]
        if not template.is_file() or sha256(template) != manifest["metadata_template"]["sha256"]:
            raise HarnessError("metadata template hash mismatch")
        _verify_runtimes(manifest)
        task = load_task()
        if task["sha256"] != manifest["task_sha256"]: raise HarnessError("task hash mismatch")
        metadata = _metadata(args.metadata, manifest["cells"])

        final_hashes: dict[str, str] = {}
        for cell in manifest["cells"]:
            _directory, solution = _verify_cell(cell); final_hashes[cell["cell"]] = sha256(solution)
            _read_attempts(cell)
        metadata_hash = sha256(args.metadata)
        _archive(staging, args.manifest, args.metadata, manifest)
        verify_hash_map(staging / "apparatus", manifest["apparatus_sha256"], "archived apparatus")
        if sha256(staging / "subject-metadata.jsonl") != metadata_hash:
            raise HarnessError("metadata changed during archive")
        for cell in manifest["cells"]:
            archived = staging / "cells" / cell["cell"]
            if sha256(archived / cell["solution"]) != final_hashes[cell["cell"]]:
                raise HarnessError(f"solution changed during archive: {cell['cell']}")
        python, machteld = _archived_runtimes(staging, manifest)
        archived_task = load_task(staging / "apparatus" / "corpus")
        archived_before = _state(staging)

        rows: list[dict[str, Any]] = []; attempt_rows: list[dict[str, Any]] = []
        for index, cell in enumerate(manifest["cells"], 1):
            row, attempts = _grade_one(cell, metadata[cell["cell"]], archived_task, python, machteld, staging, args.timeout)
            rows.append(row); attempt_rows.extend(attempts)
            if _state(staging) != archived_before:
                raise HarnessError(f"candidate mutated the archived bundle while grading: {cell['cell']}")
            print(f"[{index}/6] {'PASS' if row['hidden']['all'] else 'FAIL'} {cell['cell']} {cell['arm']} {row['hidden']['passed']}/{row['hidden']['total']}")
        atomic_write_json(staging / "rows.json", rows)
        atomic_write_json(staging / "attempt-rows.json", attempt_rows)
        atomic_write_json(staging / "summary.json", _summary(rows))
        if args.results.exists():
            (args.results / ".gitkeep").unlink(missing_ok=True); args.results.rmdir()
        os.replace(staging, args.results)
        print(f"PASS  archived and graded 6 cells; results: {args.results}")
        return 0
    except (HarnessError, OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as exc:
        if staging.exists(): remove_tree(staging)
        parser.error(str(exc))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
