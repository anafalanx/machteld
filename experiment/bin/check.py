#!/usr/bin/env python3
"""Run one candidate against visible or hidden corpus cases.

The two arms execute in child processes and report through a nonce-prefixed
protocol. A check invocation optionally appends exactly one JSONL attempt row.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
from typing import Any


REPO = Path(__file__).resolve().parents[2]
DEFAULT_MACHTELD = REPO / "build" / "machteld.exe"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _python_results(
    solution: Path, fn: str, inputs: list[list[Any]], outputs: int, timeout: float
) -> tuple[list[dict[str, Any]], str]:
    nonce = "__MEXP_" + secrets.token_hex(12) + "__"
    driver = f"""
import importlib.util, json, traceback, sys
nonce = {nonce!r}
solution = {str(solution)!r}
fn_name = {fn!r}
outputs = {outputs!r}
payload = json.load(sys.stdin)
try:
    spec = importlib.util.spec_from_file_location("machteld_experiment_solution", solution)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    target = getattr(module, fn_name)
except BaseException:
    print(nonce + json.dumps({{"load_error": traceback.format_exc()}}))
    raise SystemExit(0)
rows = []
for args in payload:
    try:
        value = target(*args)
        if outputs == 1:
            values = [value]
        elif isinstance(value, (list, tuple)) and len(value) == outputs:
            values = list(value)
        else:
            raise TypeError(f"expected {{outputs}} outputs, got {{value!r}}")
        json.dumps(values)
        rows.append({{"status": "ok", "values": values}})
    except BaseException:
        rows.append({{"status": "error", "error": traceback.format_exc()}})
print(nonce + json.dumps({{"rows": rows}}, ensure_ascii=False))
"""
    try:
        proc = subprocess.run(
            [sys.executable, "-B", "-c", driver],
            input=json.dumps(inputs),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            cwd=solution.parent,
        )
    except subprocess.TimeoutExpired:
        rows = [{"status": "error", "error": "timeout"} for _ in inputs]
        return rows, "Python candidate timed out"

    payload = None
    for line in proc.stdout.splitlines():
        if line.startswith(nonce):
            try:
                payload = json.loads(line[len(nonce) :])
            except json.JSONDecodeError:
                pass
    native = "\n".join(x for x in (proc.stdout, proc.stderr) if x).strip()
    if payload is None:
        error = native or f"Python candidate exited {proc.returncode} without a result"
        return [{"status": "error", "error": error} for _ in inputs], error
    if "load_error" in payload:
        error = payload["load_error"]
        return [{"status": "load_error", "error": error} for _ in inputs], error
    return payload["rows"], native


def _b64_text(value: str) -> str:
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def _tcl_value(value: Any) -> str:
    """Return a Tcl expression that constructs a JSON-compatible value safely."""
    if value is None:
        return "{}"
    if value is True:
        return "1"
    if value is False:
        return "0"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return repr(value)
    if isinstance(value, str):
        return f"[::__mexp::decode {{{_b64_text(value)}}}]"
    if isinstance(value, list):
        return "[list" + (" " + " ".join(_tcl_value(v) for v in value) if value else "") + "]"
    if isinstance(value, dict):
        words: list[str] = []
        for key, item in value.items():
            words.extend((_tcl_value(str(key)), _tcl_value(item)))
        return "[dict create" + (" " + " ".join(words) if words else "") + "]"
    raise TypeError(f"unsupported input value: {value!r}")


def _machteld_script(
    solution: Path, fn: str, inputs: list[list[Any]], outputs: int, nonce: str
) -> str:
    lines = [
        "namespace eval ::__mexp {}",
        "proc ::__mexp::decode {s} {",
        "    encoding convertfrom utf-8 [binary decode base64 $s]",
        "}",
        "proc ::__mexp::encode {s} {",
        "    binary encode base64 -maxlen 0 [encoding convertto utf-8 $s]",
        "}",
        f"set ::__mexp::solution [::__mexp::decode {{{_b64_text(str(solution))}}}]",
        f"set ::__mexp::fn {{{fn}}}",
        f"set ::__mexp::outputs {outputs}",
        "set ::__mexp::cases {}",
    ]
    for args in inputs:
        words = " ".join(_tcl_value(v) for v in args)
        lines.append(f"lappend ::__mexp::cases [list{(' ' + words) if words else ''}]")
    lines.extend(
        [
            "if {[catch {uplevel #0 [list source $::__mexp::solution]} __message __options]} {",
            "    set __trace [dict get $__options -errorinfo]",
            f'    puts "{nonce}\\tLOAD\\t[::__mexp::encode $__trace]"',
            "    exit 0",
            "}",
            "if {[llength [info commands ::$::__mexp::fn]] != 1} {",
            '    set __trace "required procedure ::$::__mexp::fn is not defined"',
            f'    puts "{nonce}\\tLOAD\\t[::__mexp::encode $__trace]"',
            "    exit 0",
            "}",
            "foreach __args $::__mexp::cases {",
            "    set __command [list ::$::__mexp::fn {*}$__args]",
            "    if {[catch {uplevel #0 $__command} __value __options]} {",
            "        set __trace [dict get $__options -errorinfo]",
            f'        puts "{nonce}\\tERR\\t[::__mexp::encode $__trace]"',
            "        continue",
            "    }",
            "    if {$::__mexp::outputs == 1} {",
            "        set __values [list $__value]",
            "    } elseif {[catch {llength $__value} __length] || $__length != $::__mexp::outputs} {",
            '        set __trace "expected $::__mexp::outputs outputs, got: $__value"',
            f'        puts "{nonce}\\tERR\\t[::__mexp::encode $__trace]"',
            "        continue",
            "    } else {",
            "        set __values $__value",
            "    }",
            "    set __encoded [lmap __item $__values {::__mexp::encode $__item}]",
            f'    puts "{nonce}\\tOK\\t[join $__encoded \\t]"',
            "}",
        ]
    )
    return "\n".join(lines) + "\n"


def _machteld_results(
    solution: Path, fn: str, inputs: list[list[Any]], outputs: int, timeout: float
) -> tuple[list[dict[str, Any]], str]:
    executable = Path(os.environ.get("MACHTELD_BIN", DEFAULT_MACHTELD))
    if not executable.is_file():
        error = f"machteld executable not found: {executable}"
        return [{"status": "load_error", "error": error} for _ in inputs], error

    nonce = "__MEXP_" + secrets.token_hex(12) + "__"
    script = _machteld_script(solution, fn, inputs, outputs, nonce)
    driver_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", suffix=".tcl", encoding="utf-8", newline="\n", delete=False
        ) as driver:
            driver.write(script)
            driver_path = driver.name
        proc = subprocess.run(
            [str(executable), driver_path],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            cwd=solution.parent,
        )
    except subprocess.TimeoutExpired:
        rows = [{"status": "error", "error": "timeout"} for _ in inputs]
        return rows, "machteld candidate timed out"
    finally:
        if driver_path:
            Path(driver_path).unlink(missing_ok=True)

    rows: list[dict[str, Any]] = []
    load_error: str | None = None
    for line in proc.stdout.splitlines():
        prefix = nonce + "\t"
        if not line.startswith(prefix):
            continue
        fields = line.split("\t")
        kind = fields[1] if len(fields) >= 2 else ""
        try:
            decoded = [base64.b64decode(x).decode("utf-8") for x in fields[2:]]
        except Exception as exc:
            decoded = [f"invalid checker protocol: {exc}"]
            kind = "ERR"
        if kind == "LOAD":
            load_error = decoded[0] if decoded else "solution did not load"
        elif kind == "ERR":
            rows.append({"status": "error", "error": decoded[0] if decoded else "Tcl error"})
        elif kind == "OK":
            rows.append({"status": "ok", "raw_values": decoded})

    native = "\n".join(x for x in (proc.stdout, proc.stderr) if x).strip()
    if load_error is not None:
        return [{"status": "load_error", "error": load_error} for _ in inputs], load_error
    if len(rows) != len(inputs):
        error = native or f"machteld exited {proc.returncode} with {len(rows)}/{len(inputs)} results"
        rows.extend({"status": "error", "error": error} for _ in range(len(inputs) - len(rows)))
        rows = rows[: len(inputs)]
    return rows, native


_INTEGER = re.compile(r"[+-]?[0-9]+\Z")


def _coerce_tcl(raw: str, exemplar: Any) -> Any:
    if isinstance(exemplar, bool):
        if raw in ("1", "true"):
            return True
        if raw in ("0", "false"):
            return False
        raise ValueError(f"not a Tcl boolean: {raw!r}")
    if isinstance(exemplar, int):
        if not _INTEGER.fullmatch(raw):
            raise ValueError(f"not a canonical integer: {raw!r}")
        return int(raw)
    if isinstance(exemplar, float):
        return float(raw)
    if isinstance(exemplar, str):
        return raw
    raise ValueError(f"pilot cannot decode Tcl output type {type(exemplar).__name__}")


def _python_value_matches(value: Any, exemplar: Any) -> bool:
    """JSON-shaped equality without Python's bool/int/float coercions."""
    if exemplar is None:
        return value is None
    if type(exemplar) is bool:
        return type(value) is bool and value == exemplar
    if type(exemplar) is int:
        return type(value) is int and value == exemplar
    if type(exemplar) is float:
        return type(value) is float and value == exemplar
    if type(exemplar) is str:
        return type(value) is str and value == exemplar
    if type(exemplar) is list:
        return (
            type(value) is list
            and len(value) == len(exemplar)
            and all(_python_value_matches(v, e) for v, e in zip(value, exemplar))
        )
    if type(exemplar) is dict:
        return (
            type(value) is dict
            and value.keys() == exemplar.keys()
            and all(_python_value_matches(value[key], exemplar[key]) for key in exemplar)
        )
    return type(value) is type(exemplar) and value == exemplar


def _case_passes(arm: str, row: dict[str, Any], expected: Any) -> tuple[bool, Any]:
    if expected == "FAIL":
        return row.get("status") == "error", row.get("error")
    if row.get("status") != "ok":
        return False, row.get("error")
    try:
        if arm == "machteld":
            raw = row.get("raw_values", [])
            if len(raw) != len(expected):
                return False, raw
            values = [_coerce_tcl(value, exemplar) for value, exemplar in zip(raw, expected)]
        else:
            values = row.get("values")
    except (TypeError, ValueError) as exc:
        return False, str(exc)
    if arm == "python":
        exact = (
            type(values) is list
            and len(values) == len(expected)
            and all(_python_value_matches(value, exemplar) for value, exemplar in zip(values, expected))
        )
        return exact, values
    return values == expected, values


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--arm", required=True, choices=("machteld", "python"))
    parser.add_argument("--solution", required=True, type=Path)
    parser.add_argument("--cases", required=True, type=Path)
    parser.add_argument("--fn", required=True)
    parser.add_argument("--outputs", required=True, type=int)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--machteld-sha256")
    parser.add_argument("--python-sha256")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    runtime = (
        Path(os.environ.get("MACHTELD_BIN", DEFAULT_MACHTELD)).resolve()
        if args.arm == "machteld"
        else Path(sys.executable).resolve()
    )
    expected_runtime_hash = (
        args.machteld_sha256 if args.arm == "machteld" else args.python_sha256
    )
    if not runtime.is_file():
        print(json.dumps({"infrastructure_error": f"runtime not found: {runtime}"}))
        return 2
    if expected_runtime_hash and _sha256(runtime).lower() != expected_runtime_hash.lower():
        print(json.dumps({"infrastructure_error": f"runtime hash mismatch: {runtime}"}))
        return 2

    cases = json.loads(args.cases.read_text(encoding="utf-8"))
    inputs = [case[0] for case in cases]
    runner = _machteld_results if args.arm == "machteld" else _python_results
    rows: list[dict[str, Any]] = []
    native_parts: list[str] = []
    for case_inputs in inputs:
        case_rows, case_native = runner(
            args.solution.resolve(), args.fn, [case_inputs], args.outputs, args.timeout
        )
        rows.append(case_rows[0])
        if case_native:
            native_parts.append(case_native)
    native = "\n".join(native_parts)

    verdicts: list[tuple[bool, Any]] = []
    for row, (_inputs, expected) in zip(rows, cases):
        verdicts.append(_case_passes(args.arm, row, expected))
    passed = sum(ok for ok, _got in verdicts)
    total = len(cases)

    if args.log:
        args.log.parent.mkdir(parents=True, exist_ok=True)
        attempt = 1
        if args.log.exists():
            attempt += sum(1 for line in args.log.read_text(encoding="utf-8").splitlines() if line.strip())
        record = {"attempt": attempt, "passed": passed, "total": total, "all": passed == total}
        with args.log.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(json.dumps(record, separators=(",", ":")) + "\n")

    if not args.quiet and passed != total:
        for index, ((case_inputs, expected), (ok, got), row) in enumerate(
            zip(cases, verdicts, rows)
        ):
            if not ok:
                print(f"FAIL case {index}: input={case_inputs!r} expected={expected!r} got={got!r}")
                error = row.get("error")
                if error:
                    print("--- native feedback ---")
                    print(error.rstrip())
                elif native:
                    print("--- candidate output ---")
                    print(native.rstrip())
                break
    if not args.quiet:
        print(f"{'PASS' if passed == total else 'FAIL'}  {passed}/{total} cases passed")

    summary = {"summary": {"passed": passed, "total": total, "all": passed == total}}
    print(json.dumps(summary, separators=(",", ":")))
    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
