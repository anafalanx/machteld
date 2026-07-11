#!/usr/bin/env python3
"""Verify both reference implementations on all visible and hidden cases."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
from setup_runs import (  # noqa: E402 - pinned sibling apparatus module
    EXPECTED_CORPUS_SHA256,
    EXPECTED_FIXTURE_SHA256,
    EXPECTED_MACHTELD_SHA256,
    EXPECTED_PYTHON_SHA256,
    EXPECTED_PYTHON_TREE_SHA256,
    python_semantic_tree,
)

EXP = BIN.parent
CHECK = EXP / "bin" / "check.py"
CASES = EXP / "cases" / "run_probe.json"
FIXTURE = EXP / "fixture" / "process_fixture.exe"
DEFAULT_MACHTELD = EXP / "runtime" / "machteld.exe"
ARMS = {"machteld": "tcl", "python": "py"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> int:
    if not FIXTURE.is_file():
        print(f"fixture missing: {FIXTURE}", file=sys.stderr)
        return 2
    machteld = DEFAULT_MACHTELD.resolve()
    if not machteld.is_file():
        print(f"machteld runtime missing: {machteld}", file=sys.stderr)
        return 2
    if sha256(machteld) != EXPECTED_MACHTELD_SHA256:
        print("machteld runtime differs from RUNTIME_LOCK.json", file=sys.stderr)
        return 2
    if sha256(FIXTURE) != EXPECTED_FIXTURE_SHA256:
        print("fixture differs from RUNTIME_LOCK.json", file=sys.stderr)
        return 2
    if sha256(Path(sys.executable)) != EXPECTED_PYTHON_SHA256:
        print("Python launcher differs from RUNTIME_LOCK.json", file=sys.stderr)
        return 2
    if python_semantic_tree(Path(sys.base_prefix))["sha256"] != EXPECTED_PYTHON_TREE_SHA256:
        print("Python semantic tree differs from RUNTIME_LOCK.json", file=sys.stderr)
        return 2
    if sha256(CASES) != EXPECTED_CORPUS_SHA256:
        print("case corpus differs from RUNTIME_LOCK.json", file=sys.stderr)
        return 2
    corpus = json.loads(CASES.read_text(encoding="utf-8"))
    cases = corpus["visible"] + corpus["hidden"]
    fixture_hash = sha256(FIXTURE)
    environment = os.environ.copy()
    for key in list(environment):
        if key.upper().startswith("PYTHON"):
            environment.pop(key)
    environment["MACHTELD_BIN"] = str(machteld)

    failures = 0
    with tempfile.NamedTemporaryFile(
        "w", suffix=".json", encoding="utf-8", delete=False
    ) as stream:
        json.dump(cases, stream, ensure_ascii=False)
        cases_path = Path(stream.name)
    try:
        for arm, extension in ARMS.items():
            solution = EXP / "refs" / arm / f"run_probe.{extension}"
            command = [
                sys.executable,
                "-I",
                "-S",
                "-B",
                str(CHECK),
                "--arm",
                arm,
                "--solution",
                str(solution),
                "--cases",
                str(cases_path),
                "--fixture",
                str(FIXTURE),
                "--machteld-sha256",
                sha256(machteld),
                "--python-sha256",
                sha256(Path(sys.executable)),
                "--fixture-sha256",
                fixture_hash,
                "--quiet",
            ]
            proc = subprocess.run(
                command,
                capture_output=True,
                text=True,
                encoding="utf-8",
                env=environment,
                cwd=EXP,
                timeout=60,
            )
            if proc.returncode == 0:
                print(f"PASS  run_probe {arm}")
            else:
                failures += 1
                print(f"FAIL  run_probe {arm} (exit {proc.returncode})")
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
