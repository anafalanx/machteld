#!/usr/bin/env python3
"""Grade final sandbox solutions on hidden cases and aggregate descriptively."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile
from typing import Any


EXP = Path(__file__).resolve().parents[1]
CHECK = EXP / "bin" / "check.py"
RUNS = EXP / "runs"
RESULTS = EXP / "results"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_attempts(path: Path) -> tuple[list[dict[str, Any]], str | None]:
    if not path.is_file():
        return [], None
    rows = []
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                rows.append(json.loads(line))
        for index, row in enumerate(rows, 1):
            if row.get("attempt") != index or not {"passed", "total", "all"}.issubset(row):
                raise ValueError(f"invalid attempt record {index}")
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        return [], str(exc)
    return rows, None


def source_stats(path: Path) -> tuple[int, int]:
    if not path.is_file():
        return 0, 0
    data = path.read_bytes()
    text = data.decode("utf-8", errors="replace")
    nonblank = sum(1 for line in text.splitlines() if line.strip())
    return len(data), nonblank


def aggregate(rows: list[dict[str, Any]]) -> dict[str, Any]:
    solved = [row for row in rows if row["solved"]]
    iteration_eligible = [
        row
        for row in solved
        if row["first_green"] is not None and row["attempt_log_valid"] and row["public_intact"]
    ]
    checks = [row["checks"] for row in iteration_eligible]
    first_green = [row["first_green"] for row in iteration_eligible]
    return {
        "n": len(rows),
        "solved": len(solved),
        "solve_rate": round(len(solved) / len(rows), 3) if rows else 0,
        "protocol_deviations": sum(bool(row["protocol_deviations"]) for row in rows),
        "iteration_eligible_solved": len(iteration_eligible),
        "median_checks_solved": statistics.median(checks) if checks else None,
        "mean_checks_solved": round(statistics.mean(checks), 2) if checks else None,
        "median_first_green_solved": statistics.median(first_green) if first_green else None,
        "mean_first_green_solved": round(statistics.mean(first_green), 2)
        if first_green
        else None,
        "one_check_solved": sum(1 for value in first_green if value == 1),
        "median_source_bytes_solved": statistics.median(
            [row["source_bytes"] for row in solved]
        )
        if solved
        else None,
        "median_nonblank_lines_solved": statistics.median(
            [row["nonblank_lines"] for row in solved]
        )
        if solved
        else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results-dir", type=Path, default=RESULTS)
    parser.add_argument("--force", action="store_true", help="replace an existing result bundle")
    args = parser.parse_args()
    results_dir = args.results_dir.resolve()
    existing_results = (
        [path for path in results_dir.iterdir() if path.name != ".gitkeep"]
        if results_dir.exists()
        else []
    )
    if existing_results and not args.force:
        parser.error(f"result directory is not empty; use --force to replace it: {results_dir}")

    manifest_path = RUNS / "manifest.json"
    if not manifest_path.is_file():
        print("no run manifest; run setup_runs.py first", file=sys.stderr)
        return 2
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"invalid run manifest: {exc}", file=sys.stderr)
        return 2

    python = Path(manifest["python"]["path"])
    machteld = Path(manifest["machteld"]["path"])
    for label, path, expected in (
        ("Python", python, manifest["python"]["sha256"]),
        ("machteld", machteld, manifest["machteld"]["sha256"]),
    ):
        if not path.is_file():
            print(f"{label} runtime missing: {path}", file=sys.stderr)
            return 2
        if sha256(path).lower() != expected.lower():
            print(f"{label} runtime hash drift: {path}", file=sys.stderr)
            return 2

    for relative, expected in manifest["apparatus_sha256"].items():
        path = EXP / relative
        if not path.is_file() or sha256(path).lower() != expected.lower():
            print(f"apparatus drift: {relative}; regenerate cells before grading", file=sys.stderr)
            return 2

    checker_environment = os.environ.copy()
    checker_environment["MACHTELD_BIN"] = manifest["machteld"]["path"]
    reference_check = subprocess.run(
        [str(python), "-B", str(EXP / "bin" / "verify_refs.py")],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=checker_environment,
        cwd=EXP.parent,
    )
    if reference_check.returncode != 0:
        print("reference preflight failed:", file=sys.stderr)
        print((reference_check.stdout + reference_check.stderr).rstrip(), file=sys.stderr)
        return 2

    tasks = {
        task_id: json.loads((EXP / "corpus" / f"{task_id}.json").read_text(encoding="utf-8"))
        for task_id in manifest["tasks"]
    }

    rows: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="machteld-grade-") as temporary:
        temp = Path(temporary)
        hidden_paths: dict[str, Path] = {}
        for task_id, task in tasks.items():
            path = temp / f"{task_id}.json"
            path.write_text(json.dumps(task["hidden"], ensure_ascii=False), encoding="utf-8")
            hidden_paths[task_id] = path

        for cell in manifest["cells"]:
            task = tasks[cell["task"]]
            directory = EXP / cell["directory"]
            solution = directory / cell["solution"]
            public_mismatches = []
            for filename, expected_hash in cell["public_sha256"].items():
                path = directory / filename
                if not path.is_file() or sha256(path).lower() != expected_hash.lower():
                    public_mismatches.append(filename)
            command = [
                str(python),
                "-B",
                str(CHECK),
                "--arm",
                cell["arm"],
                "--solution",
                str(solution),
                "--cases",
                str(hidden_paths[cell["task"]]),
                "--fn",
                cell["fn"],
                "--outputs",
                str(cell["outputs"]),
                "--machteld-sha256",
                manifest["machteld"]["sha256"],
                "--python-sha256",
                manifest["python"]["sha256"],
                "--quiet",
            ]
            proc = subprocess.run(
                command,
                capture_output=True,
                text=True,
                encoding="utf-8",
                env=checker_environment,
                cwd=directory,
            )
            attempts_path = EXP / cell["attempt_log"]
            attempts, attempt_error = load_attempts(attempts_path)
            first_green = next((row["attempt"] for row in attempts if row.get("all")), None)
            source_bytes, nonblank_lines = source_stats(solution)
            summary = None
            for line in proc.stdout.splitlines():
                try:
                    candidate = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "summary" in candidate:
                    summary = candidate["summary"]
            if summary is None or proc.returncode not in (0, 1):
                print(f"checker infrastructure failure in {cell['cell']} (exit {proc.returncode})")
                print((proc.stdout + proc.stderr).rstrip())
                return 2
            deviations = []
            if public_mismatches:
                deviations.append("modified public artifacts: " + ", ".join(public_mismatches))
            if attempt_error:
                deviations.append("invalid attempt log: " + attempt_error)
            if summary["all"] and first_green is None:
                deviations.append("hidden-correct without a logged visible green")
            row = {
                "cell": cell["cell"],
                "task": cell["task"],
                "arm": cell["arm"],
                "trial": cell["trial"],
                "solved": bool(summary["all"]),
                "hidden_passed": summary["passed"],
                "hidden_total": summary["total"],
                "checks": len(attempts),
                "first_green": first_green,
                "attempt_log_valid": attempt_error is None,
                "public_intact": not public_mismatches,
                "protocol_deviations": deviations,
                "source_bytes": source_bytes,
                "nonblank_lines": nonblank_lines,
                "checker_returncode": proc.returncode,
                "checker_stderr": proc.stderr,
            }
            rows.append(row)
            state = "PASS" if row["solved"] else "FAIL"
            print(
                f"{state}  {row['cell']}  {row['task']:<10} {row['arm']:<9} "
                f"hidden {row['hidden_passed']}/{row['hidden_total']} checks {row['checks']}"
                + ("  PROTOCOL" if deviations else "")
            )

    arms = manifest["arms"]
    summary = {
        "design": manifest["design"],
        "overall": {arm: aggregate([row for row in rows if row["arm"] == arm]) for arm in arms},
        "by_task": {
            task_id: {
                arm: aggregate(
                    [row for row in rows if row["task"] == task_id and row["arm"] == arm]
                )
                for arm in arms
            }
            for task_id in manifest["tasks"]
        },
    }

    if existing_results and args.force:
        root = results_dir.resolve()
        for path in existing_results:
            if path.is_symlink():
                path.unlink()
                continue
            resolved = path.resolve()
            if resolved.parent != root:
                print(f"refusing to replace unexpected result path: {path}", file=sys.stderr)
                return 2
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
    results_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(manifest_path, results_dir / "manifest.json")

    apparatus_dir = results_dir / "apparatus"
    for relative in manifest["apparatus_sha256"]:
        source = EXP / relative
        destination = apparatus_dir / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    submissions_dir = results_dir / "submissions"
    for cell in manifest["cells"]:
        destination = submissions_dir / cell["cell"]
        destination.mkdir(parents=True, exist_ok=True)
        solution = EXP / cell["directory"] / cell["solution"]
        if solution.is_file():
            shutil.copy2(solution, destination / cell["solution"])
        attempt_log = EXP / cell["attempt_log"]
        if attempt_log.is_file():
            shutil.copy2(attempt_log, destination / "attempts.jsonl")
    subject_metadata = EXP / "subject-metadata.jsonl"
    if subject_metadata.is_file():
        shutil.copy2(subject_metadata, results_dir / subject_metadata.name)

    (results_dir / "rows.json").write_text(
        json.dumps(rows, indent=2) + "\n", encoding="utf-8", newline="\n"
    )
    (results_dir / "summary.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8", newline="\n"
    )

    print("\nOverall")
    for arm in arms:
        item = summary["overall"][arm]
        print(
            f"  {arm:<9} solve {item['solved']}/{item['n']}  "
            f"median first-green {item['median_first_green_solved']}  "
            f"one-check {item['one_check_solved']}"
        )
    print(f"wrote {results_dir / 'rows.json'} and {results_dir / 'summary.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
