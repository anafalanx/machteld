#!/usr/bin/env python3
"""Regression tests for protocol, integrity, scheduling, metadata, and analysis."""

from __future__ import annotations

import ast
import json
from pathlib import Path
import subprocess
import sys
import tempfile

BIN = Path(__file__).resolve().parent
if str(BIN) not in sys.path:
    sys.path.insert(0, str(BIN))

from analysis import analyze
from bundle import verify as verify_bundle
from bundle import write as write_bundle
from check import evaluate
from common import (
    ARMS,
    HarnessError,
    MAX_VISIBLE_CHECKS,
    REFS,
    TASK_COUNT,
    discover_tasks,
    python_semantic_tree,
    sha256,
)
from record_subject import validate_row
from grade_runs import _load_metadata
from setup_runs import _schedule, default_machteld


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def metadata_row(**updates):
    row = {
        "cell": "cell-test",
        "wave": 1,
        "agent_id": "agent-test",
        "model_family": "GPT-5",
        "started_utc": "2026-07-11T10:00:00.000Z",
        "ended_utc": "2026-07-11T10:00:01.000Z",
        "status": "completed",
        "valid": True,
        "exclusion": None,
        "note": "",
    }
    row.update(updates)
    return row


def test_metadata(temp: Path) -> None:
    validate_row(metadata_row(), finished=True)
    try:
        validate_row(metadata_row(status="timed_out"), finished=True)
    except HarnessError:
        pass
    else:
        raise AssertionError("valid=true with non-completed status was accepted")
    try:
        validate_row(
            metadata_row(ended_utc="2026-07-11T09:59:59.000Z"), finished=True
        )
    except HarnessError:
        pass
    else:
        raise AssertionError("ended-before-started metadata was accepted")
    duplicate_path = temp / "duplicate-agent-metadata.jsonl"
    first = metadata_row(cell="cell-one", wave=1)
    second = metadata_row(cell="cell-two", wave=1)
    duplicate_path.write_text(
        json.dumps(first, separators=(",", ":"))
        + "\n"
        + json.dumps(second, separators=(",", ":"))
        + "\n",
        encoding="utf-8",
    )
    try:
        _load_metadata(
            duplicate_path,
            [{"cell": "cell-one", "wave": 1}, {"cell": "cell-two", "wave": 1}],
        )
    except HarnessError:
        pass
    else:
        raise AssertionError("duplicate agent_id values were accepted")


def test_python_tree(temp: Path) -> None:
    root = temp / "python-tree"
    (root / "Lib").mkdir(parents=True)
    (root / "python.exe").write_bytes(b"launcher")
    target = root / "Lib" / "module.py"
    target.write_text("x = 1\n", encoding="utf-8")
    before = python_semantic_tree(root)
    target.write_text("x = 2\n", encoding="utf-8")
    after = python_semantic_tree(root)
    require(before["sha256"] != after["sha256"], "semantic-tree tamper was not detected")


def test_protocol(temp: Path, tasks: list[dict], python: Path, machteld: Path) -> None:
    # A module global would reach 2 on the second case in a reused process.
    fresh = temp / "fresh.py"
    fresh.write_text(
        "counter = 0\ndef probe(value):\n    global counter\n    counter += 1\n    return counter\n",
        encoding="utf-8",
    )
    cases = [
        {"id": "one", "dimension": None, "inputs": [0], "expected": [1]},
        {"id": "two", "dimension": None, "inputs": [0], "expected": [1]},
    ]
    summary = evaluate(
        arm="python",
        solution=fresh,
        cases=cases,
        fn="probe",
        outputs=1,
        python_runtime=python,
        machteld_runtime=machteld,
    )
    require(summary["all"], "Python candidate process was not fresh per case")

    strict = temp / "strict.py"
    strict.write_text("def probe(value):\n    return True\n", encoding="utf-8")
    summary = evaluate(
        arm="python",
        solution=strict,
        cases=[cases[0]],
        fn="probe",
        outputs=1,
        python_runtime=python,
        machteld_runtime=machteld,
    )
    require(
        not summary["all"] and summary["cases"][0]["status"] == "contract_error",
        "bool passed as int",
    )
    invalid_output_fail_case = {
        "id": "invalid-output-is-not-fail",
        "dimension": None,
        "inputs": [0],
        "expected": "FAIL",
    }
    summary = evaluate(
        arm="python",
        solution=strict,
        cases=[invalid_output_fail_case],
        fn="probe",
        outputs=1,
        python_runtime=python,
        machteld_runtime=machteld,
    )
    require(
        not summary["all"] and summary["cases"][0]["status"] == "contract_error",
        "invalid output contract incorrectly satisfied FAIL",
    )

    shaped = temp / "shaped.py"
    shaped.write_text(
        'def probe(value):\n    print("__MSERIOUS_not_the_nonce\\tOK")\n'
        '    return value["items"][1] + value["offset"]\n',
        encoding="utf-8",
    )
    shaped_case = {
        "id": "shape",
        "dimension": None,
        "inputs": [{"items": [2, 5], "offset": 7}],
        "expected": [12],
    }
    summary = evaluate(
        arm="python",
        solution=shaped,
        cases=[shaped_case],
        fn="probe",
        outputs=1,
        python_runtime=python,
        machteld_runtime=machteld,
    )
    require(summary["all"], "JSON-shaped input or nonce filtering failed")

    failing = temp / "failing.py"
    failing.write_text("def probe(value):\n    raise ValueError('expected')\n", encoding="utf-8")
    fail_case = {"id": "fail", "dimension": None, "inputs": [1], "expected": "FAIL"}
    summary = evaluate(
        arm="python",
        solution=failing,
        cases=[fail_case],
        fn="probe",
        outputs=1,
        python_runtime=python,
        machteld_runtime=machteld,
    )
    require(summary["all"], "FAIL expectation did not accept an invocation error")

    # Regression: this must cross the real machteld process as tab-delimited
    # type/payload fields.  `[join $fields \t]` used to turn the separator into
    # a space and made every valid Tcl result a protocol failure.
    task = tasks[0]
    reference = REFS / "machteld" / f"{task['id']}.tcl"
    summary = evaluate(
        arm="machteld",
        solution=reference,
        cases=[task["visible_normalized"][0]],
        fn=task["fn"],
        outputs=task["out"],
        python_runtime=python,
        machteld_runtime=machteld,
    )
    require(summary["all"], f"real machteld tab protocol failed: {summary['cases'][0]}")

    noncanonical = temp / "noncanonical.tcl"
    noncanonical.write_text("proc probe {value} { return 01 }\n", encoding="utf-8")
    summary = evaluate(
        arm="machteld",
        solution=noncanonical,
        cases=[cases[0]],
        fn="probe",
        outputs=1,
        python_runtime=python,
        machteld_runtime=machteld,
    )
    require(not summary["all"], "non-canonical Tcl integer was accepted")


def test_check_cap(temp: Path, python: Path, machteld: Path) -> None:
    solution = temp / "cap.py"
    solution.write_text("def probe(value):\n    return value\n", encoding="utf-8")
    cases = temp / "cases.json"
    cases.write_text(json.dumps([[[1], [1]]]), encoding="utf-8")
    attempts = temp / "attempts"
    command = [
        str(python),
        "-I",
        "-S",
        "-B",
        str(BIN / "check.py"),
        "--arm",
        "python",
        "--solution",
        str(solution),
        "--cases",
        str(cases),
        "--fn",
        "probe",
        "--inputs",
        "1",
        "--outputs",
        "1",
        "--python-runtime",
        str(python),
        "--machteld-runtime",
        str(machteld),
        "--python-sha256",
        sha256(python),
        "--machteld-sha256",
        sha256(machteld),
        "--attempt-root",
        str(attempts),
        "--cell",
        "cell-cap",
        "--max-checks",
        str(MAX_VISIBLE_CHECKS),
        "--quiet",
    ]
    codes = []
    for _ in range(MAX_VISIBLE_CHECKS + 1):
        process = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
        codes.append(process.returncode)
    require(codes[:MAX_VISIBLE_CHECKS] == [0] * MAX_VISIBLE_CHECKS, "allowed check failed")
    require(codes[-1] == 3, "ninth check was not refused")
    invocations = sorted((attempts / "cell-cap").glob("invocation-*"))
    require(len(invocations) == MAX_VISIBLE_CHECKS + 1, "not every check was snapshotted")
    ninth = json.loads((invocations[-1] / "record.json").read_text(encoding="utf-8"))
    require(ninth["over_limit"] is True and ninth["executed"] is False, "bad cap record")

    broken = list(command)
    broken[broken.index("cell-cap")] = "cell-infrastructure"
    hash_index = broken.index("--python-sha256") + 1
    broken[hash_index] = "0" * 64
    process = subprocess.run(broken, capture_output=True, text=True, encoding="utf-8")
    require(process.returncode == 2, "runtime-hash failure was not infrastructure status")
    record_path = attempts / "cell-infrastructure" / "invocation-001" / "record.json"
    require(record_path.is_file(), "infrastructure-failed check did not snapshot first")
    record = json.loads(record_path.read_text(encoding="utf-8"))
    require(
        record["executed"] is False and bool(record.get("infrastructure_error")),
        "infrastructure-failed check record was not explicit",
    )


def test_schedule_and_analysis(tasks: list[dict]) -> None:
    schedule = _schedule(tasks, 20260711)
    require(len(schedule) == 180, "schedule does not have 180 cells")
    for wave in range(1, 61):
        selected = [row for row in schedule if row["wave"] == wave]
        require(len(selected) == 3, f"wave {wave} does not have three cells")
        require({row["arm"] for row in selected} == set(ARMS), f"wave {wave} lacks an arm")

    rows = []
    for task in tasks:
        for arm in ARMS:
            for trial in range(1, 4):
                rows.append(
                    {
                        "cell": f"{task['id']}-{arm}-{trial}",
                        "task": task["id"],
                        "family": task["family"],
                        "difficulty": task["difficulty"],
                        "arm": arm,
                        "trial": trial,
                        "status": "completed",
                        "valid": True,
                        "hidden": {"all": True},
                    }
                )
    first = analyze(rows, draws=10_000)
    second = analyze(rows, draws=10_000)
    require(first == second, "fixed-seed analysis is not deterministic")
    require(first["classification"] == "practically_equivalent", "ceiling did not classify equivalence")


def test_bundle(temp: Path) -> None:
    root = temp / "bundle"
    root.mkdir()
    (root / "one.txt").write_text("one\n", encoding="utf-8")
    write_bundle(root)
    verify_bundle(root)
    (root / "extra.txt").write_text("extra\n", encoding="utf-8")
    try:
        verify_bundle(root)
    except HarnessError:
        pass
    else:
        raise AssertionError("closed bundle allowed an unlisted file")


def main() -> int:
    for path in sorted(BIN.glob("*.py")):
        ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    tasks = discover_tasks()
    python = Path(sys.executable).resolve()
    machteld = default_machteld().resolve()
    require(python.is_file(), f"Python runtime missing: {python}")
    require(machteld.is_file(), f"machteld runtime missing: {machteld}")
    with tempfile.TemporaryDirectory(prefix="machteld serious selftest ") as text:
        temp = Path(text)
        test_metadata(temp)
        test_python_tree(temp)
        test_protocol(temp, tasks, python, machteld)
        test_check_cap(temp, python, machteld)
        test_schedule_and_analysis(tasks)
        test_bundle(temp)
    print("PASS  serious harness selftests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
