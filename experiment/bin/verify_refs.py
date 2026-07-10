#!/usr/bin/env python3
"""Verify both reference arms on all visible and hidden corpus cases."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile


EXP = Path(__file__).resolve().parents[1]
CHECK = EXP / "bin" / "check.py"
ARMS = {"machteld": "tcl", "python": "py"}


def main() -> int:
    failures = 0
    for task_path in sorted((EXP / "corpus").glob("*.json")):
        task = json.loads(task_path.read_text(encoding="utf-8"))
        cases = task["visible"] + task["hidden"]
        with tempfile.NamedTemporaryFile(
            "w", suffix=".json", encoding="utf-8", delete=False
        ) as stream:
            json.dump(cases, stream, ensure_ascii=False)
            cases_path = Path(stream.name)
        try:
            for arm, extension in ARMS.items():
                solution = EXP / "refs" / arm / f"{task['id']}.{extension}"
                command = [
                    sys.executable,
                    "-B",
                    str(CHECK),
                    "--arm",
                    arm,
                    "--solution",
                    str(solution),
                    "--cases",
                    str(cases_path),
                    "--fn",
                    task["fn"],
                    "--outputs",
                    str(task["out"]),
                    "--quiet",
                ]
                proc = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
                label = f"{task['id']:<16} {arm:<9}"
                if proc.returncode == 0:
                    print(f"PASS  {label}")
                else:
                    failures += 1
                    print(f"FAIL  {label}")
                    print((proc.stdout + proc.stderr).rstrip())
        finally:
            cases_path.unlink(missing_ok=True)
    if failures:
        print(f"{failures} reference verification failure(s)")
        return 1
    print("all reference solutions pass visible + hidden cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
