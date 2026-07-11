#!/usr/bin/env python3
"""Exercise checker success, rejection, cleanup, hashing, and attempt logging."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


EXP = Path(__file__).resolve().parents[1]
CHECK = EXP / "bin" / "check.py"
FIXTURE = EXP / "fixture" / "process_fixture.exe"
MACHTELD = EXP / "runtime" / "machteld.exe"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def invoke(arm: str, solution: Path, cases: Path, *extra: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
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
            str(cases),
            "--fixture",
            str(FIXTURE),
            "--machteld-sha256",
            sha256(MACHTELD),
            "--python-sha256",
            sha256(Path(sys.executable)),
            "--fixture-sha256",
            sha256(FIXTURE),
            *extra,
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=30,
        cwd=EXP,
    )


def require(label: str, condition: bool, detail: str = "") -> None:
    if not condition:
        raise RuntimeError(f"{label} failed" + (f": {detail}" if detail else ""))
    print(f"PASS  {label}")


def main() -> int:
    corpus = json.loads((EXP / "cases" / "run_probe.json").read_text(encoding="utf-8"))
    with tempfile.TemporaryDirectory(prefix="machteld-run-probe-selftest-") as temporary:
        root = Path(temporary)
        ok_cases = root / "ok.json"
        hang_cases = root / "hang.json"
        ok_cases.write_text(json.dumps([corpus["visible"][0]]), encoding="utf-8")
        hang_cases.write_text(json.dumps([corpus["visible"][2]]), encoding="utf-8")

        positive = invoke("python", EXP / "refs" / "python" / "run_probe.py", ok_cases)
        require("positive reference", positive.returncode == 0, positive.stdout + positive.stderr)

        fake_python = root / "fake.py"
        fake_python.write_text(
            'def run_probe(helper, mode, payload):\n'
            '    return ["timeout", -1, "", ""]\n',
            encoding="utf-8",
        )
        fake = invoke("python", fake_python, hang_cases)
        require("reject fabricated result", fake.returncode == 1, fake.stdout + fake.stderr)

        leaky_python = root / "leaky.py"
        leaky_python.write_text(
            "import subprocess\n\n"
            "def run_probe(helper, mode, payload):\n"
            "    subprocess.Popen([helper, mode, payload])\n"
            '    return ["timeout", -1, "", ""]\n',
            encoding="utf-8",
        )
        leaky = invoke("python", leaky_python, hang_cases)
        require("reject live direct child", leaky.returncode == 1, leaky.stdout + leaky.stderr)

        fake_tcl = root / "fake.tcl"
        fake_tcl.write_text(
            'proc run_probe {helper mode payload} { return [list timeout -1 "" ""] }\n',
            encoding="utf-8",
        )
        fake_tcl_result = invoke("machteld", fake_tcl, hang_cases)
        require(
            "reject fabricated Tcl result",
            fake_tcl_result.returncode == 1,
            fake_tcl_result.stdout + fake_tcl_result.stderr,
        )

        wrong_hash = invoke(
            "python",
            EXP / "refs" / "python" / "run_probe.py",
            ok_cases,
            "--fixture-sha256",
            "0" * 64,
        )
        require("reject fixture hash drift", wrong_hash.returncode == 2, wrong_hash.stdout)

        log = root / "attempts.jsonl"
        for _ in range(2):
            logged = invoke(
                "python",
                EXP / "refs" / "python" / "run_probe.py",
                ok_cases,
                "--log",
                str(log),
            )
            require("logged positive check", logged.returncode == 0, logged.stdout)
        attempts = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
        require(
            "attempt sequence",
            [row["attempt"] for row in attempts] == [1, 2]
            and all(row["all"] for row in attempts),
            repr(attempts),
        )

    print("all checker self-tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
