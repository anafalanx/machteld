#!/usr/bin/env python3
"""Integrity-check, hidden-grade, analyze, and archive all serious trials."""

from __future__ import annotations

import argparse
from collections import defaultdict
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

from analysis import DEFAULT_DRAWS, analyze
from check import evaluate
from common import (
    ARMS,
    ATTEMPTS,
    EXP,
    HarnessError,
    MAX_VISIBLE_CHECKS,
    RESULT_FORMAT,
    RESULTS,
    RUNS,
    TASK_COUNT,
    TRIALS_PER_ARM,
    atomic_write_json,
    apparatus_hashes,
    discover_tasks,
    load_manifest,
    python_semantic_tree,
    remove_tree_readonly,
    sha256,
    verify_hash_map,
)
from record_subject import read_rows as read_metadata_rows
from record_subject import validate_row as validate_metadata_row


def _verify_manifest(path: Path, manifest: dict[str, Any]) -> None:
    seal = path.with_suffix(".sha256")
    if not seal.is_file() or seal.read_text(encoding="ascii").strip() != sha256(path):
        raise HarnessError("manifest seal mismatch")
    cells = manifest.get("cells")
    if manifest.get("seed") != 20260711:
        raise HarnessError("manifest seed differs from the frozen serious-v1 seed")
    if manifest.get("trials_per_task_arm") != TRIALS_PER_ARM:
        raise HarnessError("manifest trial count differs from the frozen design")
    if manifest.get("max_visible_checks") != MAX_VISIBLE_CHECKS:
        raise HarnessError("manifest visible-check cap differs from the frozen design")
    if type(cells) is not list or len(cells) != TASK_COUNT * len(ARMS) * TRIALS_PER_ARM:
        raise HarnessError("manifest must contain exactly 180 cells")
    names = [cell.get("cell") for cell in cells]
    if len(set(names)) != len(names) or any(type(name) is not str for name in names):
        raise HarnessError("manifest cell ids are missing or duplicated")
    task_ids = set(manifest.get("tasks", []))
    if len(task_ids) != TASK_COUNT:
        raise HarnessError("manifest task list is not the frozen 30-task set")
    for task in task_ids:
        for arm in ARMS:
            selected = [cell for cell in cells if cell.get("task") == task and cell.get("arm") == arm]
            if len(selected) != TRIALS_PER_ARM or {cell.get("trial") for cell in selected} != {1, 2, 3}:
                raise HarnessError(f"manifest task/arm replication mismatch: {task}/{arm}")
    waves = manifest.get("waves")
    if type(waves) is not list or len(waves) != TASK_COUNT * 2:
        raise HarnessError("manifest must enumerate exactly 60 waves")
    for expected_wave, wave in enumerate(waves, 1):
        if wave.get("wave") != expected_wave or type(wave.get("cells")) is not list:
            raise HarnessError(f"invalid ordered wave {expected_wave}")
        if len(wave["cells"]) != 3 or len(set(wave["cells"])) != 3:
            raise HarnessError(f"wave {expected_wave} does not contain three unique cells")
        selected = [cell for cell in cells if cell["cell"] in wave["cells"]]
        if len(selected) != 3 or {cell["wave"] for cell in selected} != {expected_wave}:
            raise HarnessError(f"wave {expected_wave} disagrees with cell rows")
        if set(wave.get("arms", [])) != set(ARMS):
            raise HarnessError(f"wave {expected_wave} does not contain both arms")
    for block in range(1, TASK_COUNT + 1):
        selected = [cell for cell in cells if cell.get("block") == block]
        if len(selected) != 6 or any(sum(cell["arm"] == arm for cell in selected) != 3 for arm in ARMS):
            raise HarnessError(f"block {block} is not 3:3 arm-balanced")
        if len({cell["task"] for cell in selected}) != 1 or {cell["wave"] for cell in selected} != {
            2 * block - 1,
            2 * block,
        }:
            raise HarnessError(f"block {block} is not one task in two adjacent waves")


def _verify_runtimes(manifest: dict[str, Any]) -> tuple[Path, Path]:
    python = (EXP / manifest["python"]["frozen_executable"]).resolve()
    machteld = (EXP / manifest["machteld"]["frozen_executable"]).resolve()
    for label, path, expected in (
        ("Python", python, manifest["python"]["sha256"]),
        ("machteld", machteld, manifest["machteld"]["sha256"]),
    ):
        if not path.is_file() or sha256(path) != expected:
            raise HarnessError(f"{label} frozen runtime hash mismatch: {path}")
    python_root = (EXP / manifest["python"]["frozen_root"]).resolve()
    if not python.is_relative_to(python_root):
        raise HarnessError("frozen Python executable is outside its frozen semantic root")
    actual_tree = python_semantic_tree(python_root)
    expected_tree = manifest["python"]["semantic_tree"]
    for field in ("sha256", "files", "bytes", "policy"):
        if actual_tree.get(field) != expected_tree.get(field):
            raise HarnessError(f"frozen Python semantic-tree {field} mismatch")
    return python, machteld


def _load_metadata(path: Path, cells: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    cell_map = {cell["cell"]: cell for cell in cells}
    rows = read_metadata_rows(path, cell_map)
    missing = set(cell_map) - rows.keys()
    if missing:
        raise HarnessError(f"metadata is missing {len(missing)} cell(s), first: {sorted(missing)[0]}")
    if len(rows) != len(cell_map):
        raise HarnessError("metadata row count mismatch")
    for row in rows.values():
        validate_metadata_row(row, finished=True)
    families = {row["model_family"] for row in rows.values()}
    if len(families) != 1:
        raise HarnessError(f"subjects do not share one model family: {sorted(families)}")
    agent_ids = [row["agent_id"] for row in rows.values()]
    if len(set(agent_ids)) != len(agent_ids):
        raise HarnessError("metadata reuses an agent_id; every cell requires a fresh subject")
    return rows


def _verify_cell(cell: dict[str, Any]) -> tuple[Path, Path]:
    directory = (EXP / cell["directory"]).resolve()
    expected_parent = RUNS.resolve()
    if directory.parent != expected_parent or not directory.is_dir():
        raise HarnessError(f"invalid cell directory: {directory}")
    allowed = set(cell["public_sha256"]) | {cell["solution"]}
    actual = {path.name for path in directory.iterdir()}
    if actual != allowed:
        raise HarnessError(f"unexpected or missing cell files in {directory}: {sorted(actual ^ allowed)}")
    for filename, expected in cell["public_sha256"].items():
        path = directory / filename
        if not path.is_file() or sha256(path) != expected:
            raise HarnessError(f"public artifact hash mismatch: {path}")
    solution = directory / cell["solution"]
    if not solution.is_file():
        raise HarnessError(f"missing final solution: {solution}")
    return directory, solution


def _read_attempts(
    cell: dict[str, Any], directory_override: Path | None = None
) -> list[dict[str, Any]]:
    directory = directory_override if directory_override is not None else EXP / cell["attempt_directory"]
    if not directory.exists():
        return []
    if not directory.is_dir():
        raise HarnessError(f"attempt path is not a directory: {directory}")
    invocations = sorted(path for path in directory.glob("invocation-*") if path.is_dir())
    allowed_top = {path.name for path in invocations} | {"attempts.jsonl"}
    actual_top = {path.name for path in directory.iterdir()}
    if actual_top - allowed_top:
        raise HarnessError(f"unexpected attempt artifacts for {cell['cell']}: {sorted(actual_top - allowed_top)}")
    records: list[dict[str, Any]] = []
    for expected_number, invocation in enumerate(invocations, 1):
        if invocation.name != f"invocation-{expected_number:03d}":
            raise HarnessError(f"nonconsecutive invocation directory: {invocation}")
        record_path = invocation / "record.json"
        snapshot = invocation / ("solution" + Path(cell["solution"]).suffix)
        if {path.name for path in invocation.iterdir()} != {record_path.name, snapshot.name}:
            raise HarnessError(f"unexpected invocation contents: {invocation}")
        try:
            record = json.loads(record_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise HarnessError(f"invalid attempt record {record_path}: {exc}") from exc
        if record.get("attempt") != expected_number or record.get("cell") != cell["cell"]:
            raise HarnessError(f"attempt identity mismatch: {record_path}")
        if record.get("snapshot") != snapshot.name:
            raise HarnessError(f"attempt snapshot name mismatch: {record_path}")
        if not snapshot.is_file() or record.get("snapshot_sha256") != sha256(snapshot):
            raise HarnessError(f"attempt snapshot hash mismatch: {snapshot}")
        if record.get("snapshot_bytes") != snapshot.stat().st_size:
            raise HarnessError(f"attempt snapshot byte-count mismatch: {snapshot}")
        if expected_number <= MAX_VISIBLE_CHECKS:
            if record.get("over_limit") is not False:
                raise HarnessError(f"allowed invocation marked over-limit: {record_path}")
            if record.get("executed") is not True and not record.get("infrastructure_error"):
                raise HarnessError(f"unexecuted allowed invocation lacks infrastructure error: {record_path}")
        elif record.get("executed") is not False or record.get("over_limit") is not True:
            raise HarnessError(f"over-limit invocation was executed: {record_path}")
        record = dict(record)
        record["snapshot_path"] = str(snapshot)
        records.append(record)
    log = directory / "attempts.jsonl"
    if records and not log.is_file():
        raise HarnessError(f"missing attempt JSONL: {log}")
    if log.is_file():
        log_rows: list[dict[str, Any]] = []
        for line_number, line in enumerate(log.read_text(encoding="utf-8").splitlines(), 1):
            if not line.strip():
                raise HarnessError(f"blank attempt log line: {log}:{line_number}")
            log_rows.append(json.loads(line))
        comparison = [{key: value for key, value in row.items() if key != "snapshot_path"} for row in records]
        if log_rows != comparison:
            raise HarnessError(f"attempt JSONL/record mismatch: {log}")
    return records


def _source_metrics(solution: Path) -> dict[str, Any]:
    data = solution.read_bytes()
    try:
        text = data.decode("utf-8", errors="strict")
        utf8 = True
    except UnicodeDecodeError:
        text = data.decode("utf-8", errors="replace")
        utf8 = False
    return {
        "sha256": sha256(solution),
        "bytes": len(data),
        "utf8": utf8,
        "nonblank_lines": sum(bool(line.strip()) for line in text.splitlines()),
    }


def _file_state(directory: Path) -> dict[str, tuple[int, str]]:
    if not directory.exists():
        return {}
    return {
        path.relative_to(directory).as_posix(): (path.stat().st_size, sha256(path))
        for path in directory.rglob("*")
        if path.is_file()
    }


def _grade_one(
    cell: dict[str, Any],
    metadata: dict[str, Any],
    task: dict[str, Any],
    python: Path,
    machteld: Path,
    timeout: float,
    solution: Path,
    attempt_directory: Path,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    cell_state_before = _file_state(solution.parent)
    attempts_state_before = _file_state(attempt_directory)
    final_hash_before = sha256(solution)
    final_hidden = evaluate(
        arm=cell["arm"],
        solution=solution,
        cases=task["hidden_normalized"],
        fn=task["fn"],
        outputs=task["out"],
        python_runtime=python,
        machteld_runtime=machteld,
        timeout=timeout,
    )
    attempts = _read_attempts(cell, attempt_directory)
    attempt_rows: list[dict[str, Any]] = []
    first_green: int | None = None
    deviations: list[str] = []
    if metadata["valid"] is True:
        broken = [
            record
            for record in attempts
            if record["attempt"] <= MAX_VISIBLE_CHECKS and record.get("executed") is not True
        ]
        if broken:
            raise HarnessError(
                f"valid subject {cell['cell']} has an unexecuted/infrastructure-failed official check"
            )
    for record in attempts:
        snapshot = Path(record["snapshot_path"])
        visible = evaluate(
            arm=cell["arm"],
            solution=snapshot,
            cases=task["visible_normalized"],
            fn=task["fn"],
            outputs=task["out"],
            python_runtime=python,
            machteld_runtime=machteld,
            timeout=timeout,
        )
        hidden = evaluate(
            arm=cell["arm"],
            solution=snapshot,
            cases=task["hidden_normalized"],
            fn=task["fn"],
            outputs=task["out"],
            python_runtime=python,
            machteld_runtime=machteld,
            timeout=timeout,
        )
        if sha256(snapshot) != record["snapshot_sha256"]:
            raise HarnessError(f"candidate mutated archived attempt snapshot: {snapshot}")
        if record.get("executed"):
            logged = record.get("summary")
            if type(logged) is not dict or any(
                logged.get(field) != visible.get(field) for field in ("passed", "total", "all")
            ):
                raise HarnessError(f"visible attempt result mismatch: {cell['cell']} #{record['attempt']}")
            if visible["all"] and first_green is None:
                first_green = record["attempt"]
        if record.get("over_limit"):
            deviations.append("attempted_more_than_8_visible_checks")
        attempt_rows.append(
            {
                "cell": cell["cell"],
                "task": cell["task"],
                "arm": cell["arm"],
                "trial": cell["trial"],
                "attempt": record["attempt"],
                "executed": record.get("executed"),
                "over_limit": record.get("over_limit"),
                "infrastructure_error": record.get("infrastructure_error"),
                "snapshot_sha256": record["snapshot_sha256"],
                "snapshot_bytes": record["snapshot_bytes"],
                "visible": visible,
                "hidden": hidden,
            }
        )
    executed_checks = sum(record.get("executed") is True for record in attempts)
    if final_hidden["all"] and first_green is None:
        deviations.append("hidden_correct_without_visible_green")
    if sha256(solution) != final_hash_before:
        raise HarnessError(f"candidate mutated archived final solution: {solution}")
    if _file_state(solution.parent) != cell_state_before:
        raise HarnessError(f"candidate changed archived cell contents: {cell['cell']}")
    if _file_state(attempt_directory) != attempts_state_before:
        raise HarnessError(f"candidate changed archived attempt contents: {cell['cell']}")
    row = {
        "cell": cell["cell"],
        "task": cell["task"],
        "family": cell["family"],
        "difficulty": cell["difficulty"],
        "arm": cell["arm"],
        "trial": cell["trial"],
        "block": cell["block"],
        "wave": cell["wave"],
        "status": metadata["status"],
        "valid": metadata["valid"],
        "exclusion": metadata["exclusion"],
        "model_family": metadata["model_family"],
        "agent_id": metadata["agent_id"],
        "started_utc": metadata["started_utc"],
        "ended_utc": metadata["ended_utc"],
        "metadata_note": metadata["note"],
        "hidden": final_hidden,
        "blind_hidden_solve": metadata["valid"] is True and final_hidden["all"],
        "visible_checks": executed_checks,
        "first_green": first_green,
        "one_check_solve": final_hidden["all"] and first_green == 1,
        "attempt_snapshots": len(attempts),
        "protocol_deviations": sorted(set(deviations)),
        "source": _source_metrics(solution),
    }
    return row, attempt_rows


def _aggregate(rows: list[dict[str, Any]], key: str) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for value in sorted({str(row[key]) for row in rows}):
        selected = [row for row in rows if str(row[key]) == value]
        arms: dict[str, Any] = {}
        for arm in ARMS:
            arm_rows = [row for row in selected if row["arm"] == arm]
            valid = [row for row in arm_rows if row["valid"]]
            solved = [row for row in valid if row["hidden"]["all"]]
            checks = [row["visible_checks"] for row in solved]
            bytes_values = [row["source"]["bytes"] for row in solved]
            line_values = [row["source"]["nonblank_lines"] for row in solved]
            arms[arm] = {
                "assigned": len(arm_rows),
                "valid": len(valid),
                "solved": len(solved),
                "hidden_cases_passed": sum(row["hidden"]["passed"] for row in valid),
                "hidden_cases_total": sum(row["hidden"]["total"] for row in valid),
                "one_check_solves": sum(row["one_check_solve"] for row in solved),
                "median_checks_solved": statistics.median(checks) if checks else None,
                "median_bytes_solved": statistics.median(bytes_values) if bytes_values else None,
                "median_nonblank_lines_solved": statistics.median(line_values) if line_values else None,
            }
        result[value] = arms
    return result


def _archive_raw(
    *,
    staging: Path,
    manifest_path: Path,
    metadata_path: Path,
    manifest: dict[str, Any],
) -> None:
    staging.mkdir()
    shutil.copy2(manifest_path, staging / "run-manifest.json")
    shutil.copy2(manifest_path.with_suffix(".sha256"), staging / "run-manifest.sha256")
    shutil.copy2(metadata_path, staging / "subject-metadata.jsonl")
    template = EXP / manifest["metadata_template"]["path"]
    shutil.copy2(template, staging / "subject-metadata-template.jsonl")

    apparatus_root = staging / "apparatus"
    for relative in manifest["apparatus_sha256"]:
        source = EXP / relative
        target = apparatus_root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    cells_root = staging / "cells"
    for cell in manifest["cells"]:
        shutil.copytree(EXP / cell["directory"], cells_root / cell["cell"])
    attempts_root = staging / "attempts"
    attempts_root.mkdir()
    for cell in manifest["cells"]:
        source = EXP / cell["attempt_directory"]
        if source.is_dir():
            shutil.copytree(source, attempts_root / cell["cell"])
    shutil.copytree(RUNS / "_frozen", staging / "runtimes")
    runtime_record = {
        "python": manifest["python"],
        "machteld": manifest["machteld"],
    }
    atomic_write_json(staging / "runtime-lock.json", runtime_record)


def _archived_runtimes(manifest: dict[str, Any], staging: Path) -> tuple[Path, Path]:
    frozen_source_root = (RUNS / "_frozen").resolve()
    python_source = (EXP / manifest["python"]["frozen_executable"]).resolve()
    machteld_source = (EXP / manifest["machteld"]["frozen_executable"]).resolve()
    python = staging / "runtimes" / python_source.relative_to(frozen_source_root)
    machteld = staging / "runtimes" / machteld_source.relative_to(frozen_source_root)
    for label, path, expected in (
        ("archived Python", python, manifest["python"]["sha256"]),
        ("archived machteld", machteld, manifest["machteld"]["sha256"]),
    ):
        if not path.is_file() or sha256(path) != expected:
            raise HarnessError(f"{label} runtime hash mismatch: {path}")
    python_root_source = (EXP / manifest["python"]["frozen_root"]).resolve()
    python_root = staging / "runtimes" / python_root_source.relative_to(frozen_source_root)
    tree = python_semantic_tree(python_root)
    expected_tree = manifest["python"]["semantic_tree"]
    for field in ("sha256", "files", "bytes", "policy"):
        if tree.get(field) != expected_tree.get(field):
            raise HarnessError(f"archived Python semantic-tree {field} mismatch")
    return python.resolve(), machteld.resolve()


def _write_outputs(
    staging: Path,
    rows: list[dict[str, Any]],
    attempt_rows: list[dict[str, Any]],
    summary: dict[str, Any],
    analysis: dict[str, Any],
) -> None:
    atomic_write_json(staging / "rows.json", rows)
    atomic_write_json(staging / "attempt-rows.json", attempt_rows)
    atomic_write_json(staging / "summary.json", summary)
    atomic_write_json(staging / "analysis.json", analysis)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=RUNS / "manifest.json")
    parser.add_argument("--metadata", type=Path, default=EXP / "subject-metadata.jsonl")
    parser.add_argument("--results", type=Path, default=RESULTS)
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()
    staging = args.results.parent / f".{args.results.name}.staging-{os.getpid()}"
    try:
        if args.timeout <= 0:
            raise HarnessError("timeout must be positive")
        if args.results.exists():
            unexpected = [path for path in args.results.iterdir() if path.name != ".gitkeep"]
            if unexpected:
                raise HarnessError("results already exist; grading never overwrites them")
        if staging.exists():
            raise HarnessError(f"staging directory already exists: {staging}")
        manifest = load_manifest(args.manifest)
        _verify_manifest(args.manifest, manifest)
        current_apparatus = apparatus_hashes()
        if set(current_apparatus) != set(manifest["apparatus_sha256"]):
            added = sorted(set(current_apparatus) - set(manifest["apparatus_sha256"]))
            removed = sorted(set(manifest["apparatus_sha256"]) - set(current_apparatus))
            raise HarnessError(
                f"apparatus inventory changed; added={added[:5]} removed={removed[:5]}"
            )
        verify_hash_map(EXP, manifest["apparatus_sha256"], "apparatus")
        template = EXP / manifest["metadata_template"]["path"]
        if not template.is_file() or sha256(template) != manifest["metadata_template"]["sha256"]:
            raise HarnessError("subject metadata template hash mismatch")
        _verify_runtimes(manifest)
        tasks = discover_tasks()
        task_by_id = {task["id"]: task for task in tasks}
        for task_id in manifest["tasks"]:
            task = task_by_id.get(task_id)
            if task is None or task["sha256"] != next(
                cell["task_sha256"] for cell in manifest["cells"] if cell["task"] == task_id
            ):
                raise HarnessError(f"task hash mismatch: {task_id}")
            task_cells = [cell for cell in manifest["cells"] if cell["task"] == task_id]
            if any(
                cell["fn"] != task["fn"]
                or cell["inputs"] != task["in"]
                or cell["outputs"] != task["out"]
                or cell["family"] != task["family"]
                or cell["difficulty"] != task["difficulty"]
                for cell in task_cells
            ):
                raise HarnessError(f"manifest task metadata mismatch: {task_id}")
        metadata = _load_metadata(args.metadata, manifest["cells"])

        # Validate the live trial state completely, then archive it before a
        # single hidden case is executed.  Hidden grading below uses only this
        # staging snapshot, eliminating a live-submission/archive TOCTOU gap.
        final_hashes: dict[str, str] = {}
        for cell in manifest["cells"]:
            _directory, final_solution = _verify_cell(cell)
            final_hashes[cell["cell"]] = sha256(final_solution)
            _read_attempts(cell)
        metadata_hash = sha256(args.metadata)
        _archive_raw(
            staging=staging,
            manifest_path=args.manifest,
            metadata_path=args.metadata,
            manifest=manifest,
        )
        verify_hash_map(staging / "apparatus", manifest["apparatus_sha256"], "archived apparatus")
        if sha256(staging / "subject-metadata.jsonl") != metadata_hash:
            raise HarnessError("subject metadata changed while it was archived")
        for cell in manifest["cells"]:
            archived_cell = staging / "cells" / cell["cell"]
            if sha256(archived_cell / cell["solution"]) != final_hashes[cell["cell"]]:
                raise HarnessError(f"final solution changed while it was archived: {cell['cell']}")
            for filename, expected in cell["public_sha256"].items():
                if sha256(archived_cell / filename) != expected:
                    raise HarnessError(f"archived public artifact mismatch: {cell['cell']}/{filename}")
        python, machteld = _archived_runtimes(manifest, staging)
        archived_tasks = discover_tasks(staging / "apparatus" / "corpus")
        task_by_id = {task["id"]: task for task in archived_tasks}

        rows: list[dict[str, Any]] = []
        attempt_rows: list[dict[str, Any]] = []
        for index, cell in enumerate(manifest["cells"], 1):
            row, attempts = _grade_one(
                cell,
                metadata[cell["cell"]],
                task_by_id[cell["task"]],
                python,
                machteld,
                args.timeout,
                staging / "cells" / cell["cell"] / cell["solution"],
                staging / "attempts" / cell["cell"],
            )
            rows.append(row)
            attempt_rows.extend(attempts)
            print(
                f"[{index:03d}/{len(manifest['cells'])}] "
                f"{'PASS' if row['hidden']['all'] else 'FAIL'} {cell['cell']} "
                f"{cell['task']}/{cell['arm']} {row['hidden']['passed']}/{row['hidden']['total']}"
            )

        analysis_result = analyze(rows, draws=DEFAULT_DRAWS)
        overall = _aggregate(rows, "model_family")
        summary = {
            "format": RESULT_FORMAT,
            "design": manifest["design"],
            "cells": len(rows),
            "valid_cells": sum(row["valid"] for row in rows),
            "invalid_cells": sum(not row["valid"] for row in rows),
            "attempt_snapshots": len(attempt_rows),
            "overall": overall,
            "by_arm": next(iter(overall.values())) if len(overall) == 1 else None,
            "by_task": _aggregate(rows, "task"),
            "by_family": _aggregate(rows, "family"),
            "by_difficulty": _aggregate(rows, "difficulty"),
            "analysis_classification": analysis_result["classification"],
        }
        _write_outputs(staging, rows, attempt_rows, summary, analysis_result)
        if args.results.exists():
            gitkeep = args.results / ".gitkeep"
            gitkeep.unlink(missing_ok=True)
            args.results.rmdir()
        os.replace(staging, args.results)
        print(f"PASS  graded and archived {len(rows)} cells")
        print(f"analysis: {analysis_result['classification']}")
        print(f"results: {args.results}")
        return 0
    except (HarnessError, OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as exc:
        if staging.exists():
            remove_tree_readonly(staging)
        parser.error(str(exc))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
