#!/usr/bin/env python3
"""Grade hidden run_probe cases and freeze a descriptive result bundle."""

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

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
from setup_runs import (  # noqa: E402 - import is pinned from this apparatus directory
    APPARATUS_FILES,
    EXPECTED_FIXTURE_SHA256,
    EXPECTED_MACHTELD_SHA256,
    EXPECTED_PYTHON_SHA256,
    EXPECTED_PYTHON_TREE_SHA256,
    TRIALS_PER_ARM,
    python_semantic_files,
    python_semantic_tree,
)


EXP = BIN.parent
REPO = EXP.parents[1]
CHECK = EXP / "bin" / "check.py"
RUNS = EXP / "runs"
RESULTS = EXP / "results"
CASES = EXP / "cases" / "run_probe.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_attempts(path: Path) -> tuple[list[dict[str, Any]], str | None]:
    if not path.is_file():
        return [], None
    rows: list[dict[str, Any]] = []
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


def load_subject_metadata(path: Path, cell_names: list[str]) -> dict[str, dict[str, Any]]:
    if not path.is_file():
        raise ValueError(f"subject metadata missing: {path}")
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid subject metadata line {line_number}: {exc}") from exc
        required = {
            "cell",
            "wave",
            "agent_id",
            "model_family",
            "started_utc",
            "ended_utc",
            "status",
            "valid",
            "exclusion",
            "note",
        }
        if not isinstance(row, dict) or not required.issubset(row):
            raise ValueError(f"incomplete subject metadata line {line_number}")
        if type(row["valid"]) is not bool or type(row["wave"]) is not int:
            raise ValueError(f"invalid subject metadata types on line {line_number}")
        if row["valid"] and (row["status"] != "completed" or row["exclusion"] is not None):
            raise ValueError(f"valid subject has non-completed/excluded metadata on line {line_number}")
        if (
            not row["valid"]
            and (
                not isinstance(row["exclusion"], str)
                or not row["exclusion"].strip()
            )
        ):
            raise ValueError(f"excluded subject lacks a reason on line {line_number}")
        rows.append(row)
    if len(rows) != len(cell_names):
        raise ValueError(f"expected {len(cell_names)} subject rows, got {len(rows)}")
    by_cell = {str(row["cell"]): row for row in rows}
    if len(by_cell) != len(rows) or set(by_cell) != set(cell_names):
        raise ValueError("subject metadata cells are duplicated, missing, or unexpected")
    return by_cell


def source_stats(path: Path) -> tuple[int, int]:
    if not path.is_file():
        return 0, 0
    data = path.read_bytes()
    text = data.decode("utf-8", errors="replace")
    return len(data), sum(1 for line in text.splitlines() if line.strip())


def aggregate(rows: list[dict[str, Any]]) -> dict[str, Any]:
    infrastructure_failures = sum(bool(row.get("infrastructure_error")) for row in rows)
    subject_exclusions = sum(bool(row.get("subject_exclusion")) for row in rows)
    valid = [
        row
        for row in rows
        if not row.get("infrastructure_error") and not row.get("subject_exclusion")
    ]
    solved = [row for row in valid if row["solved"]]
    eligible = [
        row
        for row in solved
        if row["first_green"] is not None and row["attempt_log_valid"] and row["public_intact"]
    ]
    checks = [row["checks"] for row in eligible]
    first_green = [row["first_green"] for row in eligible]
    return {
        "assigned": len(rows),
        "n": len(valid),
        "infrastructure_failures": infrastructure_failures,
        "subject_exclusions": subject_exclusions,
        "solved": len(solved),
        "solve_rate": round(len(solved) / len(valid), 3) if valid else None,
        "protocol_deviations": sum(
            bool(row["protocol_deviations"]) for row in valid
        ),
        "iteration_eligible_solved": len(eligible),
        "median_checks_solved": statistics.median(checks) if checks else None,
        "mean_checks_solved": round(statistics.mean(checks), 2) if checks else None,
        "median_first_green_solved": statistics.median(first_green) if first_green else None,
        "mean_first_green_solved": round(statistics.mean(first_green), 2)
        if first_green
        else None,
        "one_check_solved": sum(value == 1 for value in first_green),
        "median_source_bytes_solved": statistics.median(
            row["source_bytes"] for row in solved
        )
        if solved
        else None,
        "median_nonblank_lines_solved": statistics.median(
            row["nonblank_lines"] for row in solved
        )
        if solved
        else None,
    }


def parse_summary(stdout: str) -> dict[str, Any] | None:
    found = None
    for line in stdout.splitlines():
        try:
            candidate = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict) and isinstance(candidate.get("summary"), dict):
            found = candidate["summary"]
    return found


def clean_results(root: Path, existing: list[Path]) -> None:
    resolved_root = root.resolve()
    for path in existing:
        if path.is_symlink():
            path.unlink()
            continue
        resolved = path.resolve()
        if resolved.parent != resolved_root:
            raise RuntimeError(f"refusing to replace unexpected result path: {path}")
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()


def safe_experiment_path(relative: str) -> Path:
    candidate = Path(relative)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise ValueError(f"unsafe experiment-relative path: {relative!r}")
    resolved = (EXP / candidate).resolve()
    if resolved != EXP.resolve() and EXP.resolve() not in resolved.parents:
        raise ValueError(f"path escapes experiment root: {relative!r}")
    return resolved


def validate_manifest(manifest: Any) -> None:
    if not isinstance(manifest, dict):
        raise ValueError("manifest is not an object")
    if manifest.get("design") != "machteld-vs-python-run-probe-v1":
        raise ValueError("unexpected design identifier")
    if manifest.get("task") != "run_probe" or manifest.get("arms") != ["machteld", "python"]:
        raise ValueError("unexpected task or arm order")
    if manifest.get("trials_per_arm") != TRIALS_PER_ARM:
        raise ValueError("unexpected trial count")
    if set(manifest.get("apparatus_sha256", {})) != set(APPARATUS_FILES):
        raise ValueError("apparatus inventory differs from the frozen design")
    for relative in manifest["apparatus_sha256"]:
        safe_experiment_path(relative)
    if Path(manifest["python"]["path"]).resolve() != Path(sys.executable).resolve():
        raise ValueError("grader is not running under the registered Python executable")
    if manifest["python"]["sha256"] != EXPECTED_PYTHON_SHA256:
        raise ValueError("unexpected Python launcher hash")
    if manifest["python"]["semantic_tree"]["sha256"] != EXPECTED_PYTHON_TREE_SHA256:
        raise ValueError("unexpected Python semantic tree hash")
    if Path(manifest["python"]["semantic_tree"]["root"]).resolve() != Path(sys.base_prefix).resolve():
        raise ValueError("unexpected Python semantic tree root")
    if manifest["python"].get("flags") != ["-I", "-S", "-B"]:
        raise ValueError("unexpected Python isolation flags")
    if manifest["machteld"]["sha256"] != EXPECTED_MACHTELD_SHA256:
        raise ValueError("unexpected machteld hash")
    if Path(manifest["machteld"]["path"]).resolve() != (EXP / "runtime" / "machteld.exe").resolve():
        raise ValueError("unexpected machteld path")
    if manifest["fixture"]["sha256"] != EXPECTED_FIXTURE_SHA256:
        raise ValueError("unexpected fixture hash")
    if Path(manifest["fixture"]["path"]).resolve() != (EXP / "fixture" / "process_fixture.exe").resolve():
        raise ValueError("unexpected fixture path")
    if not manifest.get("git", {}).get("head"):
        raise ValueError("missing registered Git HEAD")

    cells = manifest.get("cells")
    if not isinstance(cells, list) or len(cells) != 2 * TRIALS_PER_ARM:
        raise ValueError("manifest must contain exactly six cells")
    expected_names = [f"cell-{index:03d}" for index in range(1, 7)]
    if [cell.get("cell") for cell in cells] != expected_names:
        raise ValueError("cell names/order are invalid")
    pairs = set()
    public_names = {
        "instructions.md",
        "primer.md",
        "task.md",
        "visible.json",
        "check.cmd",
        "process fixture.exe",
    }
    for cell in cells:
        arm = cell.get("arm")
        trial = cell.get("trial")
        if arm not in {"machteld", "python"} or trial not in range(1, 4):
            raise ValueError(f"invalid arm/trial in {cell.get('cell')}")
        pairs.add((arm, trial))
        name = cell["cell"]
        if cell.get("directory") != f"runs/{name}":
            raise ValueError(f"invalid directory for {name}")
        expected_solution = "solution.tcl" if arm == "machteld" else "solution.py"
        if cell.get("solution") != expected_solution:
            raise ValueError(f"invalid solution path for {name}")
        if cell.get("attempt_log") != f"attempts/{name}.jsonl":
            raise ValueError(f"invalid attempt log for {name}")
        if set(cell.get("public_sha256", {})) != public_names:
            raise ValueError(f"invalid public artifact inventory for {name}")
        safe_experiment_path(cell["directory"])
        safe_experiment_path(cell["attempt_log"])
    if pairs != {(arm, trial) for arm in ("machteld", "python") for trial in range(1, 4)}:
        raise ValueError("arm/trial cells are not unique and complete")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results-dir", type=Path, default=RESULTS)
    parser.add_argument("--force", action="store_true", help="replace an existing result bundle")
    parser.add_argument(
        "--skip-python-runtime-copy",
        action="store_true",
        help="omit the exact pinned Python semantic files from the result bundle",
    )
    args = parser.parse_args()
    requested_results = Path(os.path.abspath(args.results_dir))
    canonical_results = Path(os.path.abspath(RESULTS))
    if requested_results != canonical_results:
        parser.error(
            "refusing a redirected result root; this grader may replace only "
            f"{canonical_results}"
        )
    is_junction = getattr(RESULTS, "is_junction", lambda: False)
    if RESULTS.is_symlink() or is_junction():
        parser.error(f"refusing a linked/junction result root: {RESULTS}")
    results_dir = RESULTS.resolve()
    if results_dir.parent != EXP.resolve() or results_dir.name != "results":
        parser.error(f"canonical result root escaped the experiment: {results_dir}")
    existing = (
        [path for path in results_dir.iterdir() if path.name != ".gitkeep"]
        if results_dir.exists()
        else []
    )
    if existing and not args.force:
        parser.error(f"result directory is not empty; use --force to replace it: {results_dir}")

    manifest_path = RUNS / "manifest.json"
    if not manifest_path.is_file():
        print("no run manifest; run setup_runs.py first", file=sys.stderr)
        return 2
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        validate_manifest(manifest)
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
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
    current_python_tree = python_semantic_tree(Path(manifest["python"]["semantic_tree"]["root"]))
    if current_python_tree["sha256"] != manifest["python"]["semantic_tree"]["sha256"]:
        print("Python semantic runtime tree drift", file=sys.stderr)
        return 2
    for relative, expected in manifest["apparatus_sha256"].items():
        path = EXP / relative
        if not path.is_file() or sha256(path).lower() != expected.lower():
            print(f"apparatus drift: {relative}; regenerate cells before grading", file=sys.stderr)
            return 2
    git_head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=REPO,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if git_head.returncode != 0 or git_head.stdout.strip() != manifest["git"]["head"]:
        print("Git HEAD differs from the registered apparatus commit", file=sys.stderr)
        return 2

    environment = os.environ.copy()
    for key in list(environment):
        if key.upper().startswith("PYTHON"):
            environment.pop(key)
    environment["MACHTELD_BIN"] = str(machteld)
    reference_check = subprocess.run(
        [str(python), "-I", "-S", "-B", str(EXP / "bin" / "verify_refs.py")],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=environment,
        cwd=EXP,
        timeout=90,
    )
    if reference_check.returncode != 0:
        print("reference preflight failed:", file=sys.stderr)
        print((reference_check.stdout + reference_check.stderr).rstrip(), file=sys.stderr)
        return 2

    corpus = json.loads(CASES.read_text(encoding="utf-8"))
    try:
        subject_metadata = load_subject_metadata(
            EXP / "subject-metadata.jsonl",
            [str(cell["cell"]) for cell in manifest["cells"]],
        )
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"invalid subject metadata: {exc}", file=sys.stderr)
        return 2
    rows: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="machteld-run-probe-grade-") as temporary:
        temporary_root = Path(temporary)
        hidden_path = temporary_root / "hidden.json"
        hidden_path.write_text(
            json.dumps(corpus["hidden"], ensure_ascii=False), encoding="utf-8", newline="\n"
        )
        grading_fixture = temporary_root / "process fixture.exe"
        shutil.copy2(EXP / "fixture" / "process_fixture.exe", grading_fixture)
        if sha256(grading_fixture) != manifest["fixture"]["sha256"]:
            print("cannot create hash-identical hidden grading fixture", file=sys.stderr)
            return 2
        for cell in manifest["cells"]:
            subject = subject_metadata[cell["cell"]]
            directory = EXP / cell["directory"]
            solution = directory / cell["solution"]
            # Grade with the canonical pinned fixture. A changed cell copy is
            # still recorded as a protocol deviation, but cannot abort the
            # other five trials as a checker infrastructure failure.
            fixture = grading_fixture
            mismatches = []
            for filename, expected_hash in cell["public_sha256"].items():
                path = directory / filename
                if not path.is_file() or sha256(path).lower() != expected_hash.lower():
                    mismatches.append(filename)
            command = [
                str(python),
                "-I",
                "-S",
                "-B",
                str(CHECK),
                "--arm",
                cell["arm"],
                "--solution",
                str(solution),
                "--cases",
                str(hidden_path),
                "--fixture",
                str(fixture),
                "--machteld-sha256",
                manifest["machteld"]["sha256"],
                "--python-sha256",
                manifest["python"]["sha256"],
                "--fixture-sha256",
                manifest["fixture"]["sha256"],
                "--quiet",
            ]
            checker_infrastructure_error = None
            try:
                proc = subprocess.run(
                    command,
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    env=environment,
                    cwd=directory,
                    timeout=90,
                )
                summary = parse_summary(proc.stdout)
                if summary is None or proc.returncode not in (0, 1):
                    checker_infrastructure_error = (
                        f"checker exit {proc.returncode}: "
                        + (proc.stdout + proc.stderr).strip()[:8000]
                    )
            except subprocess.TimeoutExpired as exc:
                proc = None
                summary = None
                checker_infrastructure_error = f"checker exceeded 90s: {exc}"
            if checker_infrastructure_error:
                summary = {
                    "passed": 0,
                    "total": len(corpus["hidden"]),
                    "all": False,
                    "cases": [],
                }
            attempts_path = EXP / cell["attempt_log"]
            attempts, attempt_error = load_attempts(attempts_path)
            first_green = next((row["attempt"] for row in attempts if row.get("all")), None)
            source_bytes, nonblank_lines = source_stats(solution)
            deviations = []
            if mismatches:
                deviations.append("modified public artifacts: " + ", ".join(mismatches))
            if attempt_error:
                deviations.append("invalid attempt log: " + attempt_error)
            if checker_infrastructure_error:
                deviations.append("infrastructure: " + checker_infrastructure_error)
            subject_exclusion = None if subject["valid"] else subject["exclusion"]
            if subject_exclusion:
                deviations.append("subject excluded: " + subject_exclusion)
            if summary["all"] and first_green is None:
                deviations.append("hidden-correct without a logged visible green")
            row = {
                "cell": cell["cell"],
                "task": "run_probe",
                "arm": cell["arm"],
                "trial": cell["trial"],
                "solved": bool(summary["all"]),
                "hidden_passed": summary["passed"],
                "hidden_total": summary["total"],
                "hidden_cases": summary.get("cases", []),
                "checks": len(attempts),
                "first_green": first_green,
                "attempt_log_valid": attempt_error is None,
                "public_intact": not mismatches,
                "protocol_deviations": deviations,
                "infrastructure_error": checker_infrastructure_error,
                "subject_exclusion": subject_exclusion,
                "subject": subject,
                "source_bytes": source_bytes,
                "nonblank_lines": nonblank_lines,
                "checker_returncode": proc.returncode if proc is not None else None,
                "checker_stderr": proc.stderr if proc is not None else "",
            }
            rows.append(row)
            state = (
                "INFRA"
                if checker_infrastructure_error
                else "EXCLUDED"
                if subject_exclusion
                else "PASS"
                if row["solved"]
                else "FAIL"
            )
            print(
                f"{state}  {row['cell']}  {row['arm']:<9} "
                f"hidden {row['hidden_passed']}/{row['hidden_total']} checks {row['checks']}"
                + ("  PROTOCOL" if deviations else "")
            )

    case_ids = [str(case.get("id", index)) for index, case in enumerate(corpus["hidden"])]
    per_case: dict[str, dict[str, dict[str, int]]] = {}
    for case_index, case_id in enumerate(case_ids):
        per_case[case_id] = {}
        for arm in manifest["arms"]:
            arm_rows = [
                row
                for row in rows
                if row["arm"] == arm
                and not row.get("infrastructure_error")
                and not row.get("subject_exclusion")
            ]
            passed = 0
            reported = 0
            for row in arm_rows:
                details = row["hidden_cases"]
                if case_index < len(details):
                    reported += 1
                    if details[case_index].get("passed"):
                        passed += 1
            per_case[case_id][arm] = {"passed": passed, "n": reported}

    dimensions = sorted({str(case["dimension"]) for case in corpus["hidden"]})
    per_dimension: dict[str, dict[str, dict[str, int]]] = {}
    for dimension in dimensions:
        per_dimension[dimension] = {}
        for arm in manifest["arms"]:
            details = [
                detail
                for row in rows
                if row["arm"] == arm
                and not row.get("infrastructure_error")
                and not row.get("subject_exclusion")
                for detail in row["hidden_cases"]
                if detail.get("dimension") == dimension
            ]
            per_dimension[dimension][arm] = {
                "passed": sum(bool(detail.get("passed")) for detail in details),
                "n": len(details),
            }

    summary_doc = {
        "design": manifest["design"],
        "overall": {
            arm: aggregate([row for row in rows if row["arm"] == arm])
            for arm in manifest["arms"]
        },
        "by_hidden_case": per_case,
        "by_dimension": per_dimension,
    }

    if existing and args.force:
        try:
            clean_results(results_dir, existing)
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 2
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
    subject_metadata_path = EXP / "subject-metadata.jsonl"
    if subject_metadata_path.is_file():
        shutil.copy2(subject_metadata_path, results_dir / subject_metadata_path.name)

    (results_dir / "rows.json").write_text(
        json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n"
    )
    (results_dir / "summary.json").write_text(
        json.dumps(summary_doc, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )

    runtime_dir = results_dir / "runtime"
    runtime_dir.mkdir(parents=True, exist_ok=True)
    machteld_copy = runtime_dir / "machteld.exe"
    shutil.copy2(machteld, machteld_copy)
    runtime_doc: dict[str, Any] = {
        "machteld.exe": {"sha256": sha256(machteld_copy), "bytes": machteld_copy.stat().st_size},
        "python_semantic_tree": manifest["python"]["semantic_tree"],
        "original_python_path": str(Path(manifest["python"]["semantic_tree"]["root"])),
    }
    if not args.skip_python_runtime_copy:
        python_root = Path(manifest["python"]["semantic_tree"]["root"])
        python_copy = runtime_dir / "python"
        for source in python_semantic_files(python_root):
            destination = python_copy / source.relative_to(python_root)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        copied_tree = python_semantic_tree(python_copy)
        if copied_tree["sha256"] != manifest["python"]["semantic_tree"]["sha256"]:
            print("copied Python runtime tree hash mismatch", file=sys.stderr)
            return 2
        runtime_doc["python_copy"] = {
            "relative_path": "python",
            "sha256": copied_tree["sha256"],
            "files": copied_tree["files"],
            "bytes": copied_tree["bytes"],
        }
    (runtime_dir / "runtime.json").write_text(
        json.dumps(runtime_doc, indent=2) + "\n", encoding="utf-8", newline="\n"
    )

    print("\nOverall")
    for arm in manifest["arms"]:
        item = summary_doc["overall"][arm]
        print(
            f"  {arm:<9} solve {item['solved']}/{item['n']}  "
            f"median first-green {item['median_first_green_solved']}  "
            f"one-check {item['one_check_solved']}"
        )
    print(f"wrote staged raw results to {results_dir}")
    print(
        "write REPORT.md, then run experiment/run_probe/bin/bundle.py write "
        "and experiment/run_probe/bin/bundle.py verify"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
