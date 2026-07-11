#!/usr/bin/env python3
"""Run one kvstore candidate on visible or hidden cases.

Every case uses a fresh process. Official visible invocations archive the exact
source before any runtime, case, or integrity check is performed.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
from typing import Any

BIN = Path(__file__).resolve().parent
if str(BIN) not in sys.path:
    sys.path.insert(0, str(BIN))

from common import HarnessError, MAX_VISIBLE_CHECKS, normalize_cases, sha256


PREFIX = "__MKVSTORE_"


def _b64(text: str) -> str:
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def _unb64(text: str) -> str:
    return base64.b64decode(text, validate=True).decode("utf-8", errors="strict")


def _parse(stdout: str, stderr: str, nonce: str) -> dict[str, Any]:
    rows = [line for line in stdout.splitlines() if line.startswith(nonce + "\t")]
    native_stdout = "\n".join(line for line in stdout.splitlines() if not line.startswith(nonce + "\t"))
    native = "\n".join(part for part in (native_stdout, stderr) if part).strip()[:8000]
    if len(rows) != 1:
        return {"status": "protocol_error", "error": f"expected one protocol row, got {len(rows)}", "native": native}
    fields = rows[0].split("\t")
    try:
        if len(fields) == 3 and fields[1] in {"LOAD", "CALL", "ERR"}:
            detail = _unb64(fields[2])
            if native:
                detail += "\n--- candidate output ---\n" + native
            return {
                "status": "load_error" if fields[1] == "LOAD" else "error" if fields[1] == "CALL" else "contract_error",
                "error": detail,
                "native": native,
            }
        if len(fields) != 3 or fields[1] != "OK":
            raise ValueError("malformed protocol fields")
        value = _unb64(fields[2])
    except (ValueError, UnicodeError, binascii.Error) as exc:
        return {"status": "protocol_error", "error": f"invalid protocol: {exc}", "native": native}
    return {"status": "ok", "values": [value], "native": native}


def _python_driver(solution: Path, nonce: str) -> str:
    return f'''import base64, importlib.util, json, traceback, sys
nonce = {nonce!r}
def enc(value): return base64.b64encode(value.encode("utf-8")).decode("ascii")
try:
    args = json.load(sys.stdin)
    spec = importlib.util.spec_from_file_location("kvstore_candidate", {str(solution)!r})
    if spec is None or spec.loader is None: raise ImportError("cannot create solution module spec")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    target = getattr(module, "run")
except BaseException:
    print(nonce + "\\tLOAD\\t" + enc(traceback.format_exc())); raise SystemExit(0)
try:
    value = target(*args)
except BaseException:
    print(nonce + "\\tCALL\\t" + enc(traceback.format_exc())); raise SystemExit(0)
if type(value) is not str:
    print(nonce + "\\tERR\\t" + enc("run must return an exact string, got " + type(value).__name__))
else:
    print(nonce + "\\tOK\\t" + enc(value))
'''


def _tcl_value(value: Any) -> str:
    if type(value) is str:
        return "[::__mkv::decode {" + _b64(value) + "}]"
    if type(value) is list:
        words = " ".join(_tcl_value(item) for item in value)
        return "[list" + (" " + words if words else "") + "]"
    if value is None:
        return "{}"
    if type(value) is bool:
        return "1" if value else "0"
    if type(value) in {int, float}:
        return repr(value)
    if type(value) is dict:
        words: list[str] = []
        for key, item in value.items():
            words.extend((_tcl_value(key), _tcl_value(item)))
        return "[dict create" + (" " + " ".join(words) if words else "") + "]"
    raise HarnessError(f"unsupported Tcl input: {value!r}")


def _tcl_driver(solution: Path, arguments: list[Any], nonce: str) -> str:
    args = " ".join(_tcl_value(value) for value in arguments)
    source = "[::__mkv::decode {" + _b64(str(solution)) + "}]"
    return f'''namespace eval ::__mkv {{}}
proc ::__mkv::decode {{value}} {{ encoding convertfrom utf-8 [binary decode base64 $value] }}
proc ::__mkv::encode {{value}} {{ binary encode base64 -maxlen 0 [encoding convertto utf-8 $value] }}
set ::__mkv::source {source}
set ::__mkv::args [list{(' ' + args) if args else ''}]
if {{[catch {{uplevel #0 [list source $::__mkv::source]}} msg opts]}} {{
    puts "{nonce}\tLOAD\t[::__mkv::encode [dict get $opts -errorinfo]]"; exit 0
}}
if {{[llength [info commands ::run]] != 1}} {{
    puts "{nonce}\tLOAD\t[::__mkv::encode {{required procedure ::run is not defined}}]"; exit 0
}}
if {{[catch {{uplevel #0 [list ::run {{*}}$::__mkv::args]}} value opts]}} {{
    puts "{nonce}\tCALL\t[::__mkv::encode [dict get $opts -errorinfo]]"; exit 0
}}
puts "{nonce}\tOK\t[::__mkv::encode $value]"
'''


def _run_case(arm: str, runtime: Path, solution: Path, case: dict[str, Any], timeout: float) -> tuple[dict[str, Any], int]:
    nonce = PREFIX + secrets.token_hex(16)
    started = time.perf_counter()
    temporary: Path | None = None
    try:
        if arm == "python":
            environment = os.environ.copy()
            for key in tuple(environment):
                if key.upper().startswith("PYTHON"):
                    environment.pop(key)
            process = subprocess.run(
                [str(runtime), "-I", "-S", "-B", "-c", _python_driver(solution, nonce)],
                input=json.dumps(case["inputs"], ensure_ascii=True), capture_output=True,
                text=True, encoding="utf-8", errors="replace", timeout=timeout,
                cwd=solution.parent, env=environment,
            )
        else:
            with tempfile.NamedTemporaryFile("w", suffix=".tcl", encoding="utf-8", newline="\n", delete=False) as stream:
                stream.write(_tcl_driver(solution, case["inputs"], nonce))
                temporary = Path(stream.name)
            process = subprocess.run(
                [str(runtime), str(temporary)], capture_output=True, text=True,
                encoding="utf-8", errors="replace", timeout=timeout, cwd=solution.parent,
            )
    except subprocess.TimeoutExpired as exc:
        elapsed = round((time.perf_counter() - started) * 1000)
        stdout = exc.stdout.decode("utf-8", "replace") if isinstance(exc.stdout, bytes) else exc.stdout
        stderr = exc.stderr.decode("utf-8", "replace") if isinstance(exc.stderr, bytes) else exc.stderr
        return {"status": "timeout", "error": f"candidate watchdog expired after {timeout:g}s", "native": "\n".join(p for p in (stdout or "", stderr or "") if p)[:8000]}, elapsed
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return _parse(process.stdout, process.stderr, nonce), round((time.perf_counter() - started) * 1000)


def evaluate(*, arm: str, solution: Path, cases: list[dict[str, Any]], python_runtime: Path,
             machteld_runtime: Path, timeout: float = 10.0) -> dict[str, Any]:
    if arm not in {"machteld", "python"}:
        raise HarnessError(f"unknown arm: {arm}")
    runtime = machteld_runtime if arm == "machteld" else python_runtime
    if not solution.is_file() or not runtime.is_file():
        raise HarnessError("solution or runtime is missing")
    rows: list[dict[str, Any]] = []
    for case in cases:
        observation, elapsed = _run_case(arm, runtime, solution, case, timeout)
        expected = case["expected"]
        passed = observation.get("status") == "error" if expected == "FAIL" else observation.get("status") == "ok" and observation.get("values") == expected
        rows.append({"id": case["id"], "passed": passed, "elapsed_ms": elapsed,
                     "status": observation.get("status"), "got": observation.get("values"),
                     "error": observation.get("error")})
    count = sum(row["passed"] for row in rows)
    return {"passed": count, "total": len(rows), "all": count == len(rows), "cases": rows}


def _begin_attempt(root: Path, cell: str, solution: Path) -> tuple[Path, dict[str, Any]]:
    directory = root / cell
    directory.mkdir(parents=True, exist_ok=True)
    indices = [int(path.name[-3:]) for path in directory.glob("invocation-[0-9][0-9][0-9]") if path.is_dir()]
    number = max(indices, default=0) + 1
    invocation = directory / f"invocation-{number:03d}"
    invocation.mkdir(exist_ok=False)
    snapshot = invocation / ("solution" + solution.suffix.lower())
    shutil.copyfile(solution, snapshot)
    return invocation, {"attempt": number, "cell": cell, "snapshot": snapshot.name,
                        "snapshot_sha256": sha256(snapshot), "snapshot_bytes": snapshot.stat().st_size,
                        "started_unix_ns": time.time_ns()}


def _finish_attempt(invocation: Path, root: Path, cell: str, record: dict[str, Any]) -> None:
    record["ended_unix_ns"] = time.time_ns()
    text = json.dumps(record, ensure_ascii=False, indent=2) + "\n"
    (invocation / "record.json").write_text(text, encoding="utf-8", newline="\n")
    with (root / cell / "attempts.jsonl").open("a", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--arm", required=True, choices=("machteld", "python"))
    parser.add_argument("--solution", required=True, type=Path)
    parser.add_argument("--cases", required=True, type=Path)
    parser.add_argument("--python-runtime", required=True, type=Path)
    parser.add_argument("--machteld-runtime", required=True, type=Path)
    parser.add_argument("--python-sha256", required=True)
    parser.add_argument("--machteld-sha256", required=True)
    parser.add_argument("--attempt-root", type=Path)
    parser.add_argument("--cell")
    parser.add_argument("--max-checks", type=int, default=MAX_VISIBLE_CHECKS)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    if bool(args.attempt_root) != bool(args.cell):
        parser.error("--attempt-root and --cell must be supplied together")
    invocation: Path | None = None
    record: dict[str, Any] | None = None
    try:
        if args.timeout <= 0 or args.max_checks < 1:
            raise HarnessError("invalid timeout or check cap")
        if args.attempt_root:
            invocation, record = _begin_attempt(args.attempt_root.resolve(), args.cell, args.solution.resolve())
            if record["attempt"] > args.max_checks:
                record.update({"executed": False, "over_limit": True, "max_checks": args.max_checks})
                _finish_attempt(invocation, args.attempt_root.resolve(), args.cell, record)
                print(f"REFUSED  visible-check limit is {args.max_checks}")
                return 3
        for label, path, expected in (("Python", args.python_runtime.resolve(), args.python_sha256),
                                      ("machteld", args.machteld_runtime.resolve(), args.machteld_sha256)):
            if not path.is_file() or sha256(path) != expected:
                raise HarnessError(f"{label} runtime missing or hash-mismatched")
        cases = normalize_cases(json.loads(args.cases.read_text(encoding="utf-8")), str(args.cases))
        summary = evaluate(arm=args.arm, solution=args.solution.resolve(), cases=cases,
                           python_runtime=args.python_runtime.resolve(), machteld_runtime=args.machteld_runtime.resolve(),
                           timeout=args.timeout)
        if record is not None and invocation is not None:
            record.update({"executed": True, "over_limit": False, "summary": summary})
            _finish_attempt(invocation, args.attempt_root.resolve(), args.cell, record)
        if not args.quiet:
            if summary["all"]:
                print(f"PASS  {summary['passed']}/{summary['total']} cases passed")
            else:
                first = next(row for row in summary["cases"] if not row["passed"])
                print(f"FAIL {first['id']}: status={first['status']} got={first['got']!r}")
                if first.get("error"):
                    print(str(first["error"]).rstrip())
                print(f"FAIL  {summary['passed']}/{summary['total']} cases passed")
        print(json.dumps({"summary": summary}, ensure_ascii=True, separators=(",", ":")))
        return 0 if summary["all"] else 1
    except (HarnessError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        detail = f"{type(exc).__name__}: {exc}"
        if record is not None and invocation is not None:
            record.update({"executed": False, "over_limit": False, "infrastructure_error": detail})
            _finish_attempt(invocation, args.attempt_root.resolve(), args.cell, record)
        print(json.dumps({"infrastructure_error": detail}, ensure_ascii=True))
        return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
    except Exception:
        print(json.dumps({"infrastructure_error": traceback.format_exc()}, ensure_ascii=True))
        raise SystemExit(2)
