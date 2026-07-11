#!/usr/bin/env python3
"""Evaluate one serious-experiment candidate.

Each case receives a fresh candidate process.  Results cross the process
boundary as one nonce-prefixed row whose string payloads are strict UTF-8
base64.  Official visible checks snapshot the solution before execution.
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


PROTOCOL_PREFIX = "__MSERIOUS_"
CANONICAL_INTEGER = re.compile(r"-?(?:0|[1-9][0-9]*)\Z")


def encode_text(value: str) -> str:
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def decode_text(value: str) -> str:
    return base64.b64decode(value, validate=True).decode("utf-8", errors="strict")


def _native_feedback(stdout: str, stderr: str, nonce: str) -> str:
    kept = "\n".join(
        line for line in stdout.splitlines() if not line.startswith(nonce + "\t")
    )
    return "\n".join(part for part in (kept, stderr) if part).strip()[:8000]


def parse_protocol(stdout: str, stderr: str, nonce: str, outputs: int) -> dict[str, Any]:
    rows = [line for line in stdout.splitlines() if line.startswith(nonce + "\t")]
    native = _native_feedback(stdout, stderr, nonce)
    if len(rows) != 1:
        detail = f"expected exactly one checker protocol row, got {len(rows)}"
        if native:
            detail += "\n" + native
        return {"status": "protocol_error", "error": detail, "native": native}
    fields = rows[0].split("\t")
    try:
        if len(fields) == 3 and fields[1] in {"LOAD", "CALL", "ERR"}:
            detail = decode_text(fields[2])
            if native:
                detail += "\n--- candidate output ---\n" + native
            return {
                "status": (
                    "load_error"
                    if fields[1] == "LOAD"
                    else "error"
                    if fields[1] == "CALL"
                    else "contract_error"
                ),
                "error": detail,
                "native": native,
            }
        if fields[1] != "OK" or len(fields) != 2 + 2 * outputs:
            raise ValueError("malformed protocol fields")
        values: list[int | str] = []
        for index in range(outputs):
            kind = fields[2 + 2 * index]
            text = decode_text(fields[3 + 2 * index])
            if kind == "I":
                if not CANONICAL_INTEGER.fullmatch(text):
                    raise ValueError(f"non-canonical integer: {text!r}")
                values.append(int(text))
            elif kind == "S":
                values.append(text)
            else:
                raise ValueError(f"unknown output type marker {kind!r}")
    except (IndexError, ValueError, UnicodeError, binascii.Error) as exc:
        detail = f"invalid checker protocol: {exc}"
        if native:
            detail += "\n" + native
        return {"status": "protocol_error", "error": detail, "native": native}
    return {"status": "ok", "values": values, "native": native}


def _python_driver(solution: Path, fn: str, outputs: int, nonce: str) -> str:
    return f'''import base64, importlib.util, json, traceback, sys
nonce = {nonce!r}
solution = {str(solution)!r}
fn_name = {fn!r}
outputs = {outputs!r}

def enc(value):
    return base64.b64encode(value.encode("utf-8")).decode("ascii")

try:
    invocation = json.load(sys.stdin)
    spec = importlib.util.spec_from_file_location("serious_candidate", solution)
    if spec is None or spec.loader is None:
        raise ImportError("cannot create solution module spec")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    target = getattr(module, fn_name)
except BaseException:
    print(nonce + "\\tLOAD\\t" + enc(traceback.format_exc()))
    raise SystemExit(0)

try:
    value = target(*invocation)
except BaseException:
    print(nonce + "\\tCALL\\t" + enc(traceback.format_exc()))
    raise SystemExit(0)

try:
    if outputs == 1:
        values = [value]
    elif type(value) in (list, tuple) and len(value) == outputs:
        values = list(value)
    else:
        raise TypeError(f"expected {{outputs}} outputs, got {{value!r}}")
    fields = []
    for item in values:
        if type(item) is int:
            fields.extend(("I", enc(str(item))))
        elif type(item) is str:
            fields.extend(("S", enc(item)))
        else:
            raise TypeError("outputs must be exact int or str values; got " +
                            type(item).__name__)
    print(nonce + "\\tOK\\t" + "\\t".join(fields))
except BaseException:
    print(nonce + "\\tERR\\t" + enc(traceback.format_exc()))
'''


def _run_python_case(
    runtime: Path,
    solution: Path,
    fn: str,
    outputs: int,
    case: dict[str, Any],
    timeout: float,
) -> tuple[dict[str, Any], int]:
    nonce = PROTOCOL_PREFIX + secrets.token_hex(16)
    driver = _python_driver(solution, fn, outputs, nonce)
    environment = os.environ.copy()
    for key in tuple(environment):
        if key.upper().startswith("PYTHON"):
            environment.pop(key)
    started = time.perf_counter()
    try:
        process = subprocess.run(
            [str(runtime), "-I", "-S", "-B", "-c", driver],
            input=json.dumps(case["inputs"], ensure_ascii=True),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            cwd=solution.parent,
            env=environment,
        )
    except subprocess.TimeoutExpired as exc:
        elapsed = round((time.perf_counter() - started) * 1000)
        stdout = exc.stdout.decode("utf-8", "replace") if isinstance(exc.stdout, bytes) else exc.stdout
        stderr = exc.stderr.decode("utf-8", "replace") if isinstance(exc.stderr, bytes) else exc.stderr
        native = "\n".join(part for part in (stdout or "", stderr or "") if part).strip()
        detail = f"candidate watchdog expired after {timeout:g}s"
        if native:
            detail += "\n" + native[:8000]
        return {"status": "timeout", "error": detail, "native": native}, elapsed
    elapsed = round((time.perf_counter() - started) * 1000)
    return parse_protocol(process.stdout, process.stderr, nonce, outputs), elapsed


def _tcl_value(value: Any) -> str:
    if value is None:
        return "{}"
    if value is True:
        return "1"
    if value is False:
        return "0"
    if type(value) is int:
        return str(value)
    if type(value) is float:
        return repr(value)
    if type(value) is str:
        return "[::__mserious::decode {" + encode_text(value) + "}]"
    if type(value) is list:
        rendered = " ".join(_tcl_value(item) for item in value)
        return "[list" + (" " + rendered if rendered else "") + "]"
    if type(value) is dict:
        words: list[str] = []
        for key, item in value.items():
            words.extend((_tcl_value(key), _tcl_value(item)))
        return "[dict create" + (" " + " ".join(words) if words else "") + "]"
    raise HarnessError(f"unsupported Tcl input value: {value!r}")


def _tcl_driver(
    solution: Path,
    fn: str,
    outputs: int,
    case: dict[str, Any],
    nonce: str,
) -> str:
    args = " ".join(_tcl_value(value) for value in case["inputs"])
    expected = case["expected"]
    expected_kinds = [] if expected == "FAIL" else ["I" if type(v) is int else "S" for v in expected]
    kinds = " ".join("{" + item + "}" for item in expected_kinds)
    solution_value = "[::__mserious::decode {" + encode_text(str(solution)) + "}]"
    return f'''namespace eval ::__mserious {{}}
proc ::__mserious::decode {{value}} {{
    encoding convertfrom utf-8 [binary decode base64 $value]
}}
proc ::__mserious::encode {{value}} {{
    binary encode base64 -maxlen 0 [encoding convertto utf-8 $value]
}}
set ::__mserious::solution {solution_value}
set ::__mserious::fn {{{fn}}}
set ::__mserious::outputs {outputs}
set ::__mserious::kinds [list {kinds}]
set ::__mserious::args [list{(' ' + args) if args else ''}]
if {{[catch {{uplevel #0 [list source $::__mserious::solution]}} __message __options]}} {{
    puts "{nonce}\tLOAD\t[::__mserious::encode [dict get $__options -errorinfo]]"
    exit 0
}}
if {{[llength [info commands ::$::__mserious::fn]] != 1}} {{
    puts "{nonce}\tLOAD\t[::__mserious::encode \"required procedure ::$::__mserious::fn is not defined\"]"
    exit 0
}}
if {{[catch {{uplevel #0 [list ::$::__mserious::fn {{*}}$::__mserious::args]}} __value __options]}} {{
    puts "{nonce}\tCALL\t[::__mserious::encode [dict get $__options -errorinfo]]"
    exit 0
}}
if {{$::__mserious::outputs == 1}} {{
    set __values [list $__value]
}} elseif {{[catch {{llength $__value}} __length] || $__length != $::__mserious::outputs}} {{
    puts "{nonce}\tERR\t[::__mserious::encode \"expected $::__mserious::outputs outputs, got: $__value\"]"
    exit 0
}} else {{
    set __values $__value
}}
set __fields {{}}
for {{set __i 0}} {{$__i < [llength $__values]}} {{incr __i}} {{
    set __item [lindex $__values $__i]
    set __kind [lindex $::__mserious::kinds $__i]
    if {{$__kind eq "I" && ![regexp {{^-?(0|[1-9][0-9]*)$}} $__item]}} {{
        puts "{nonce}\tERR\t[::__mserious::encode \"integer output must be canonical, got: $__item\"]"
        exit 0
    }}
    if {{$__kind eq ""}} {{set __kind S}}
    lappend __fields $__kind [::__mserious::encode $__item]
}}
puts "{nonce}\tOK\t[join $__fields \"\t\"]"
'''


def _run_machteld_case(
    runtime: Path,
    solution: Path,
    fn: str,
    outputs: int,
    case: dict[str, Any],
    timeout: float,
) -> tuple[dict[str, Any], int]:
    nonce = PROTOCOL_PREFIX + secrets.token_hex(16)
    driver_text = _tcl_driver(solution, fn, outputs, case, nonce)
    driver_path: Path | None = None
    started = time.perf_counter()
    try:
        with tempfile.NamedTemporaryFile(
            "w", suffix=".tcl", encoding="utf-8", newline="\n", delete=False
        ) as stream:
            stream.write(driver_text)
            driver_path = Path(stream.name)
        process = subprocess.run(
            [str(runtime), str(driver_path)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            cwd=solution.parent,
        )
    except subprocess.TimeoutExpired as exc:
        elapsed = round((time.perf_counter() - started) * 1000)
        stdout = exc.stdout.decode("utf-8", "replace") if isinstance(exc.stdout, bytes) else exc.stdout
        stderr = exc.stderr.decode("utf-8", "replace") if isinstance(exc.stderr, bytes) else exc.stderr
        native = "\n".join(part for part in (stdout or "", stderr or "") if part).strip()
        detail = f"candidate watchdog expired after {timeout:g}s"
        if native:
            detail += "\n" + native[:8000]
        return {"status": "timeout", "error": detail, "native": native}, elapsed
    finally:
        if driver_path is not None:
            driver_path.unlink(missing_ok=True)
    elapsed = round((time.perf_counter() - started) * 1000)
    return parse_protocol(process.stdout, process.stderr, nonce, outputs), elapsed


def case_passes(observation: dict[str, Any], expected: str | list[int | str]) -> bool:
    if expected == "FAIL":
        return observation.get("status") == "error"
    return observation.get("status") == "ok" and observation.get("values") == expected


def evaluate(
    *,
    arm: str,
    solution: Path,
    cases: list[dict[str, Any]],
    fn: str,
    outputs: int,
    python_runtime: Path,
    machteld_runtime: Path,
    timeout: float = 10.0,
) -> dict[str, Any]:
    if arm not in {"machteld", "python"}:
        raise HarnessError(f"unknown arm: {arm}")
    runtime = machteld_runtime if arm == "machteld" else python_runtime
    if not solution.is_file():
        raise HarnessError(f"solution not found: {solution}")
    if not runtime.is_file():
        raise HarnessError(f"runtime not found: {runtime}")
    runner = _run_machteld_case if arm == "machteld" else _run_python_case
    verdicts: list[dict[str, Any]] = []
    for case in cases:
        observation, elapsed_ms = runner(runtime, solution, fn, outputs, case, timeout)
        passed = case_passes(observation, case["expected"])
        verdicts.append(
            {
                "id": case["id"],
                "dimension": case.get("dimension"),
                "passed": passed,
                "elapsed_ms": elapsed_ms,
                "status": observation.get("status"),
                "got": observation.get("values"),
                "error": observation.get("error"),
            }
        )
    passed_count = sum(row["passed"] for row in verdicts)
    return {
        "passed": passed_count,
        "total": len(verdicts),
        "all": passed_count == len(verdicts),
        "cases": verdicts,
    }


def _begin_attempt(attempt_root: Path, cell: str, solution: Path) -> tuple[int, Path, dict[str, Any]]:
    directory = attempt_root / cell
    directory.mkdir(parents=True, exist_ok=True)
    indices: list[int] = []
    for path in directory.glob("invocation-*"):
        if path.is_dir() and re.fullmatch(r"invocation-[0-9]{3}", path.name):
            indices.append(int(path.name.rsplit("-", 1)[1]))
    number = max(indices, default=0) + 1
    invocation = directory / f"invocation-{number:03d}"
    invocation.mkdir(exist_ok=False)
    snapshot = invocation / ("solution" + solution.suffix.lower())
    shutil.copyfile(solution, snapshot)
    record = {
        "attempt": number,
        "cell": cell,
        "snapshot": snapshot.name,
        "snapshot_sha256": sha256(snapshot),
        "snapshot_bytes": snapshot.stat().st_size,
        "started_unix_ns": time.time_ns(),
    }
    return number, invocation, record


def _finish_attempt(invocation: Path, attempt_root: Path, cell: str, record: dict[str, Any]) -> None:
    record["ended_unix_ns"] = time.time_ns()
    record_path = invocation / "record.json"
    record_path.write_text(
        json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n"
    )
    log = attempt_root / cell / "attempts.jsonl"
    with log.open("a", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")


def _print_feedback(summary: dict[str, Any]) -> None:
    if summary["all"]:
        print(f"PASS  {summary['passed']}/{summary['total']} cases passed")
        return
    for row in summary["cases"]:
        if not row["passed"]:
            print(
                f"FAIL {row['id']}: status={row['status']} got={row['got']!r}"
            )
            if row.get("error"):
                print("--- native feedback ---")
                print(str(row["error"]).rstrip())
            break
    print(f"FAIL  {summary['passed']}/{summary['total']} cases passed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--arm", required=True, choices=("machteld", "python"))
    parser.add_argument("--solution", required=True, type=Path)
    parser.add_argument("--cases", required=True, type=Path)
    parser.add_argument("--fn", required=True)
    parser.add_argument("--inputs", required=True, type=int)
    parser.add_argument("--outputs", required=True, type=int)
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
    if args.inputs < 0 or args.outputs < 1 or args.timeout <= 0 or args.max_checks < 1:
        parser.error("invalid arity, timeout, or check cap")
    if bool(args.attempt_root) != bool(args.cell):
        parser.error("--attempt-root and --cell must be supplied together")

    invocation: Path | None = None
    record: dict[str, Any] | None = None
    try:
        # Snapshot first: even an apparatus/hash/case failure must not lose the
        # exact subject source that requested this official check.
        if args.attempt_root is not None:
            number, invocation, record = _begin_attempt(
                args.attempt_root.resolve(), str(args.cell), args.solution.resolve()
            )
            if number > args.max_checks:
                record.update(
                    {
                        "executed": False,
                        "over_limit": True,
                        "max_checks": args.max_checks,
                    }
                )
                _finish_attempt(invocation, args.attempt_root.resolve(), str(args.cell), record)
                print(f"REFUSED  visible-check limit is {args.max_checks}")
                return 3
        for label, runtime, expected in (
            ("Python", args.python_runtime.resolve(), args.python_sha256),
            ("machteld", args.machteld_runtime.resolve(), args.machteld_sha256),
        ):
            if not runtime.is_file() or sha256(runtime).lower() != expected.lower():
                raise HarnessError(f"{label} runtime missing or hash-mismatched: {runtime}")
        raw_cases = json.loads(args.cases.read_text(encoding="utf-8"))
        cases = normalize_cases(raw_cases, args.inputs, args.outputs, str(args.cases))
        summary = evaluate(
            arm=args.arm,
            solution=args.solution.resolve(),
            cases=cases,
            fn=args.fn,
            outputs=args.outputs,
            python_runtime=args.python_runtime.resolve(),
            machteld_runtime=args.machteld_runtime.resolve(),
            timeout=args.timeout,
        )
        if record is not None and invocation is not None:
            record.update({"executed": True, "over_limit": False, "summary": summary})
            _finish_attempt(invocation, args.attempt_root.resolve(), str(args.cell), record)
        if not args.quiet:
            _print_feedback(summary)
        print(json.dumps({"summary": summary}, ensure_ascii=True, separators=(",", ":")))
        return 0 if summary["all"] else 1
    except (HarnessError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        detail = f"{type(exc).__name__}: {exc}"
        if record is not None and invocation is not None:
            record.update({"executed": False, "over_limit": False, "infrastructure_error": detail})
            _finish_attempt(invocation, args.attempt_root.resolve(), str(args.cell), record)
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
