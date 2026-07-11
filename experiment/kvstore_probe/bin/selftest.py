#!/usr/bin/env python3
"""Non-destructive harness self-tests; leaves generated trial state unchanged."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

BIN = Path(__file__).resolve().parent
if str(BIN) not in sys.path: sys.path.insert(0, str(BIN))

import bundle
from check import evaluate
from common import ARMS, ATTEMPTS, DESIGN, EXP, HarnessError, RESULTS, RUNS, load_task, sha256
from record_subject import validate_row
from setup_runs import SERIOUS_RESULTS, _schedule


def _generated_state() -> dict[str, tuple[int, str]]:
    selected: dict[str, tuple[int, str]] = {}
    for root in (RUNS, ATTEMPTS, RESULTS):
        if root.exists():
            for path in root.rglob("*"):
                if path.is_file(): selected[path.relative_to(EXP).as_posix()] = (path.stat().st_size, sha256(path))
    metadata = EXP / "subject-metadata.jsonl"
    if metadata.is_file(): selected[metadata.name] = (metadata.stat().st_size, sha256(metadata))
    return selected


def require(condition: bool, message: str) -> None:
    if not condition: raise AssertionError(message)


def main() -> int:
    before = _generated_state()
    task = load_task()
    require(DESIGN.endswith("kvstore-supplement-v1"), "wrong design id")
    require(len(task["visible_normalized"]) == 3 and len(task["hidden_normalized"]) == 59, "case counts")
    schedule = _schedule()
    require(schedule == _schedule() and len(schedule) == 6, "schedule is not deterministic")
    require(len({row["cell"] for row in schedule}) == 6, "opaque cell collision")
    require(all(sum(row["arm"] == arm for row in schedule) == 3 for arm in ARMS), "arm balance")
    require(all(len([row for row in schedule if row["wave"] == wave]) == 3 for wave in (1, 2)), "wave sizes")
    for position in (1, 2, 3):
        pair = [row["arm"] for row in schedule if row["wave_position"] == position]
        require(len(pair) == 2 and pair[0] != pair[1], "wave positions are not complementary")

    python = SERIOUS_RESULTS / "runtimes" / "python" / "python.exe"
    machteld = SERIOUS_RESULTS / "runtimes" / "machteld.exe"
    for arm, extension in ARMS.items():
        reference = EXP / "refs" / arm / f"kvstore.{extension}"
        summary = evaluate(arm=arm, solution=reference, cases=task["visible_normalized"],
                           python_runtime=python, machteld_runtime=machteld, timeout=10.0)
        require(summary["all"], f"visible reference failed: {arm}")

    validate_row({"cell": "x", "wave": 1, "agent_id": "fresh-1", "model_family": "test",
                  "started_utc": "2026-07-11T00:00:00.000Z", "ended_utc": "2026-07-11T00:00:01.000Z",
                  "status": "completed", "valid": True, "exclusion": None, "note": ""}, True)

    with tempfile.TemporaryDirectory(prefix="mkv-selftest-") as name:
        root = Path(name); candidate = root / "solution.py"
        shutil.copyfile(EXP / "refs" / "python" / "kvstore.py", candidate)
        cases = root / "visible.json"
        cases.write_text(json.dumps(task["visible"][:1]), encoding="utf-8")
        attempts = root / "attempts"
        command = [sys.executable, "-I", "-S", "-B", str(BIN / "check.py"), "--arm", "python", "--solution", str(candidate),
                   "--cases", str(cases), "--python-runtime", str(python), "--machteld-runtime", str(machteld),
                   "--python-sha256", sha256(python), "--machteld-sha256", sha256(machteld),
                   "--attempt-root", str(attempts), "--cell", "selftest-cell", "--max-checks", "1", "--quiet"]
        first = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
        second = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
        require(first.returncode == 0 and second.returncode == 3, "visible check cap")
        records = [json.loads(line) for line in (attempts / "selftest-cell" / "attempts.jsonl").read_text(encoding="utf-8").splitlines()]
        require(len(records) == 2 and records[0]["executed"] is True and records[1]["over_limit"] is True, "attempt records")
        require(all((attempts / "selftest-cell" / f"invocation-{index:03d}" / "solution.py").is_file() for index in (1, 2)), "snapshot-before-limit")

        result = root / "bundle"; result.mkdir(); (result / "rows.json").write_text("[]\n", encoding="utf-8")
        digest = bundle.write(result); require(bundle.verify(result) == digest, "bundle round trip")
        (result / "rows.json").write_text("tampered\n", encoding="utf-8")
        try: bundle.verify(result)
        except HarnessError: pass
        else: raise AssertionError("bundle tamper was not detected")

    require(_generated_state() == before, "selftest changed generated trial state")
    print("PASS  kvstore harness self-tests")
    return 0


if __name__ == "__main__": raise SystemExit(main())
