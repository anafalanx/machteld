#!/usr/bin/env python3
"""Run run_probe candidates against visible or hidden cases.

Every case loads the candidate in a fresh runtime process. Candidate results
cross the runtime boundary through a nonce-prefixed, base64 text protocol.
The native fixture publishes its PID out of band so the checker can prove that
the helper was launched and is no longer alive when run_probe returns.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import time
import traceback
from typing import Any


EXP = Path(__file__).resolve().parents[1]
DEFAULT_MACHTELD = EXP / "runtime" / "machteld.exe"
PROTOCOL_PREFIX = "__MRUN_"
CANONICAL_INTEGER = re.compile(r"-?(?:0|[1-9][0-9]*)\Z")
PROCESS_SYNCHRONIZE = 0x00100000
PROCESS_TERMINATE = 0x0001
WAIT_OBJECT_0 = 0
WAIT_TIMEOUT = 258
ERROR_INVALID_PARAMETER = 87


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def encode_text(value: str) -> str:
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def decode_text(value: str) -> str:
    return base64.b64decode(value, validate=True).decode("utf-8", errors="strict")


def short(value: Any, limit: int = 240) -> str:
    rendered = repr(value)
    return rendered if len(rendered) <= limit else rendered[: limit - 3] + "..."


def native_feedback(stdout: str, stderr: str, nonce: str) -> str:
    kept_stdout = "\n".join(
        line for line in stdout.splitlines() if not line.startswith(nonce + "\t")
    )
    combined = "\n".join(part for part in (kept_stdout, stderr) if part).strip()
    return combined[:8000]


def parse_protocol(stdout: str, stderr: str, nonce: str) -> dict[str, Any]:
    rows = [line for line in stdout.splitlines() if line.startswith(nonce + "\t")]
    native = native_feedback(stdout, stderr, nonce)
    if len(rows) != 1:
        detail = f"expected exactly one checker protocol row, got {len(rows)}"
        if native:
            detail += "\n" + native
        return {"status": "error", "error": detail}
    fields = rows[0].split("\t")
    try:
        if len(fields) == 3 and fields[1] == "ERR":
            detail = decode_text(fields[2])
            if native:
                detail += "\n--- candidate output ---\n" + native
            return {"status": "error", "error": detail}
        if len(fields) != 6 or fields[1] != "OK":
            raise ValueError("malformed protocol fields")
        exit_text = fields[3]
        if not CANONICAL_INTEGER.fullmatch(exit_text):
            raise ValueError(f"non-canonical exit integer: {exit_text!r}")
        values = [
            decode_text(fields[2]),
            int(exit_text),
            decode_text(fields[4]),
            decode_text(fields[5]),
        ]
    except (ValueError, UnicodeError, binascii.Error) as exc:
        detail = f"invalid checker protocol: {exc}"
        if native:
            detail += "\n" + native
        return {"status": "error", "error": detail}
    return {"status": "ok", "values": values, "native": native}


def python_driver(solution: Path, nonce: str) -> str:
    return f'''import base64, importlib.util, json, traceback, sys
nonce = {nonce!r}
solution = {str(solution)!r}

def enc(value):
    return base64.b64encode(value.encode("utf-8")).decode("ascii")

try:
    invocation = json.load(sys.stdin)
    spec = importlib.util.spec_from_file_location("machteld_run_probe_solution", solution)
    module = importlib.util.module_from_spec(spec)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load solution module")
    spec.loader.exec_module(module)
    target = getattr(module, "run_probe")
    value = target(invocation["helper"], invocation["mode"], invocation["payload"])
    if not isinstance(value, (list, tuple)) or len(value) != 4:
        raise TypeError(f"expected a four-element list/tuple, got {{value!r}}")
    status, exit_code, out, err = value
    if type(status) is not str:
        raise TypeError(f"status must be str, got {{type(status).__name__}}")
    if type(exit_code) is not int:
        raise TypeError(f"exit must be int, got {{type(exit_code).__name__}}")
    if type(out) is not str or type(err) is not str:
        raise TypeError("out and err must be str")
    print(nonce + "\\tOK\\t" + enc(status) + "\\t" + str(exit_code) +
          "\\t" + enc(out) + "\\t" + enc(err))
except BaseException:
    print(nonce + "\\tERR\\t" + enc(traceback.format_exc()))
'''


def run_python_case(
    runtime: Path,
    solution: Path,
    fixture: Path,
    case: dict[str, Any],
    environment: dict[str, str],
    timeout: float,
) -> tuple[dict[str, Any], float]:
    nonce = PROTOCOL_PREFIX + secrets.token_hex(16)
    driver = python_driver(solution, nonce)
    invocation = {
        "helper": str(fixture),
        "mode": case["mode"],
        "payload": case["payload"],
    }
    started = time.perf_counter()
    try:
        proc = subprocess.run(
            [str(runtime), "-I", "-S", "-B", "-c", driver],
            # Keep the driver transport ASCII so it does not depend on the
            # pinned interpreter's Windows stdin code page.
            input=json.dumps(invocation, ensure_ascii=True),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            cwd=solution.parent,
            env=environment,
        )
    except subprocess.TimeoutExpired as exc:
        elapsed = time.perf_counter() - started
        stdout = exc.stdout.decode("utf-8", "replace") if isinstance(exc.stdout, bytes) else exc.stdout
        stderr = exc.stderr.decode("utf-8", "replace") if isinstance(exc.stderr, bytes) else exc.stderr
        detail = f"candidate watchdog expired after {timeout:g}s"
        native = "\n".join(part for part in (stdout or "", stderr or "") if part).strip()
        if native:
            detail += "\n" + native[:8000]
        return {"status": "error", "error": detail}, elapsed
    elapsed = time.perf_counter() - started
    return parse_protocol(proc.stdout, proc.stderr, nonce), elapsed


def tcl_literal(value: str) -> str:
    return "[::__mrun::decode {" + encode_text(value) + "}]"


def tcl_driver(
    solution: Path, fixture: Path, case: dict[str, Any], nonce: str
) -> str:
    return f'''namespace eval ::__mrun {{}}
proc ::__mrun::decode {{value}} {{
    encoding convertfrom utf-8 [binary decode base64 $value]
}}
proc ::__mrun::encode {{value}} {{
    binary encode base64 -maxlen 0 [encoding convertto utf-8 $value]
}}
set ::__mrun::solution {tcl_literal(str(solution))}
set ::__mrun::helper {tcl_literal(str(fixture))}
set ::__mrun::mode {tcl_literal(case["mode"])}
set ::__mrun::payload {tcl_literal(case["payload"])}
if {{[catch {{uplevel #0 [list source $::__mrun::solution]}} __message __options]}} {{
    set __trace [dict get $__options -errorinfo]
    puts "{nonce}\\tERR\\t[::__mrun::encode $__trace]"
    exit 0
}}
if {{[llength [info commands ::run_probe]] != 1}} {{
    puts "{nonce}\\tERR\\t[::__mrun::encode {{required procedure ::run_probe is not defined}}]"
    exit 0
}}
if {{[catch {{uplevel #0 [list ::run_probe $::__mrun::helper $::__mrun::mode $::__mrun::payload]}} __value __options]}} {{
    set __trace [dict get $__options -errorinfo]
    puts "{nonce}\\tERR\\t[::__mrun::encode $__trace]"
    exit 0
}}
if {{[catch {{llength $__value}} __length] || $__length != 4}} {{
    puts "{nonce}\\tERR\\t[::__mrun::encode \"expected a four-element Tcl list, got: $__value\"]"
    exit 0
}}
set __status [lindex $__value 0]
set __exit [lindex $__value 1]
set __out [lindex $__value 2]
set __err [lindex $__value 3]
if {{![regexp {{^-?(0|[1-9][0-9]*)$}} $__exit]}} {{
    puts "{nonce}\\tERR\\t[::__mrun::encode \"exit must be a canonical integer, got: $__exit\"]"
    exit 0
}}
puts "{nonce}\\tOK\\t[::__mrun::encode $__status]\\t$__exit\\t[::__mrun::encode $__out]\\t[::__mrun::encode $__err]"
'''


def run_machteld_case(
    runtime: Path,
    solution: Path,
    fixture: Path,
    case: dict[str, Any],
    environment: dict[str, str],
    timeout: float,
) -> tuple[dict[str, Any], float]:
    nonce = PROTOCOL_PREFIX + secrets.token_hex(16)
    script = tcl_driver(solution, fixture, case, nonce)
    driver_path: Path | None = None
    started = time.perf_counter()
    try:
        with tempfile.NamedTemporaryFile(
            "w", suffix=".tcl", encoding="utf-8", newline="\n", delete=False
        ) as stream:
            stream.write(script)
            driver_path = Path(stream.name)
        proc = subprocess.run(
            [str(runtime), str(driver_path)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            cwd=solution.parent,
            env=environment,
        )
    except subprocess.TimeoutExpired as exc:
        elapsed = time.perf_counter() - started
        stdout = exc.stdout.decode("utf-8", "replace") if isinstance(exc.stdout, bytes) else exc.stdout
        stderr = exc.stderr.decode("utf-8", "replace") if isinstance(exc.stderr, bytes) else exc.stderr
        detail = f"candidate watchdog expired after {timeout:g}s"
        native = "\n".join(part for part in (stdout or "", stderr or "") if part).strip()
        if native:
            detail += "\n" + native[:8000]
        return {"status": "error", "error": detail}, elapsed
    finally:
        if driver_path is not None:
            driver_path.unlink(missing_ok=True)
    elapsed = time.perf_counter() - started
    return parse_protocol(proc.stdout, proc.stderr, nonce), elapsed


def process_state(pid: int) -> tuple[str, str | None]:
    """Return alive, dead, or unknown for a Windows PID."""
    if os.name != "nt":
        return "unknown", "run_probe experiment requires Windows"
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel32.WaitForSingleObject.restype = wintypes.DWORD
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    handle = kernel32.OpenProcess(PROCESS_SYNCHRONIZE, False, pid)
    if not handle:
        error = ctypes.get_last_error()
        if error == ERROR_INVALID_PARAMETER:
            return "dead", None
        return "unknown", f"OpenProcess({pid}) failed with Windows error {error}"
    try:
        wait = kernel32.WaitForSingleObject(handle, 0)
    finally:
        kernel32.CloseHandle(handle)
    if wait == WAIT_TIMEOUT:
        return "alive", None
    if wait == WAIT_OBJECT_0:
        return "dead", None
    return "unknown", f"WaitForSingleObject({pid}) returned {wait}"


def read_pid(marker: Path, wait_seconds: float = 0.35) -> tuple[int | None, str | None]:
    deadline = time.perf_counter() + wait_seconds
    while not marker.is_file() and time.perf_counter() < deadline:
        time.sleep(0.01)
    if not marker.is_file():
        return None, "fixture did not publish a PID; it may not have been launched"
    try:
        text = marker.read_text(encoding="ascii")
        if not re.fullmatch(r"[1-9][0-9]*", text):
            raise ValueError(f"invalid PID text {text!r}")
        return int(text), None
    except (OSError, UnicodeError, ValueError) as exc:
        return None, f"cannot read fixture PID marker: {exc}"


def wait_for_dead(pid: int, wait_seconds: float = 0.25) -> tuple[str, str | None]:
    deadline = time.perf_counter() + wait_seconds
    while True:
        state, error = process_state(pid)
        if state != "alive" or time.perf_counter() >= deadline:
            return state, error
        time.sleep(0.01)


def kill_survivor(pid: int) -> str | None:
    """Terminate the direct fixture with Win32 APIs and verify it stopped."""
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    kernel32.TerminateProcess.restype = wintypes.BOOL
    kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel32.WaitForSingleObject.restype = wintypes.DWORD
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel32.OpenProcess(PROCESS_TERMINATE | PROCESS_SYNCHRONIZE, False, pid)
    if not handle:
        error = ctypes.get_last_error()
        return None if error == ERROR_INVALID_PARAMETER else f"cannot open survivor {pid}: {error}"
    try:
        if not kernel32.TerminateProcess(handle, 1):
            return f"TerminateProcess({pid}) failed: {ctypes.get_last_error()}"
        wait = kernel32.WaitForSingleObject(handle, 2000)
        if wait != WAIT_OBJECT_0:
            return f"survivor {pid} did not terminate (wait result {wait})"
    finally:
        kernel32.CloseHandle(handle)
    state, error = process_state(pid)
    if state == "alive":
        return f"survivor {pid} remained alive after TerminateProcess"
    if state == "unknown":
        return error or f"could not verify termination of survivor {pid}"
    return None


def validate_cases(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise ValueError("cases must be a nonempty JSON list")
    result: list[dict[str, Any]] = []
    for index, case in enumerate(value):
        if not isinstance(case, dict):
            raise ValueError(f"case {index} must be an object")
        if case.get("mode") not in {"ok", "fail", "hang"}:
            raise ValueError(f"case {index} has invalid mode")
        if type(case.get("payload")) is not str:
            raise ValueError(f"case {index} payload must be a string")
        expected = case.get("expected")
        if (
            not isinstance(expected, list)
            or len(expected) != 4
            or type(expected[0]) is not str
            or type(expected[1]) is not int
            or type(expected[2]) is not str
            or type(expected[3]) is not str
        ):
            raise ValueError(f"case {index} has invalid expected result")
        result.append(case)
    return result


def append_attempt(path: Path, passed: int, total: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    attempt = 1
    if path.exists():
        attempt += sum(1 for line in path.read_text(encoding="utf-8").splitlines() if line.strip())
    record = {"attempt": attempt, "passed": passed, "total": total, "all": passed == total}
    with path.open("a", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(record, separators=(",", ":")) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--arm", required=True, choices=("machteld", "python"))
    parser.add_argument("--solution", required=True, type=Path)
    parser.add_argument("--cases", required=True, type=Path)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--outer-timeout", type=float, default=3.0)
    parser.add_argument("--machteld-sha256")
    parser.add_argument("--python-sha256")
    parser.add_argument("--fixture-sha256")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    if args.outer_timeout <= 0:
        parser.error("--outer-timeout must be positive")

    runtime = (
        Path(os.environ.get("MACHTELD_BIN", DEFAULT_MACHTELD)).resolve()
        if args.arm == "machteld"
        else Path(sys.executable).resolve()
    )
    fixture = args.fixture.resolve()
    expected_runtime_hash = (
        args.machteld_sha256 if args.arm == "machteld" else args.python_sha256
    )
    for label, path, expected_hash in (
        ("runtime", runtime, expected_runtime_hash),
        ("fixture", fixture, args.fixture_sha256),
    ):
        if not path.is_file():
            print(json.dumps({"infrastructure_error": f"{label} not found: {path}"}))
            return 2
        if expected_hash and sha256(path).lower() != expected_hash.lower():
            print(json.dumps({"infrastructure_error": f"{label} hash mismatch: {path}"}))
            return 2
    try:
        cases = validate_cases(json.loads(args.cases.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(json.dumps({"infrastructure_error": f"invalid cases: {exc}"}))
        return 2

    runner = run_machteld_case if args.arm == "machteld" else run_python_case
    verdicts: list[dict[str, Any]] = []
    infrastructure_error: str | None = None
    with tempfile.TemporaryDirectory(prefix="machteld probe markers ") as marker_root_text:
        marker_root = Path(marker_root_text)
        for index, case in enumerate(cases):
            marker = marker_root / f"case {index + 1} pid.txt"
            environment = os.environ.copy()
            for key in list(environment):
                if key.upper().startswith("PYTHON"):
                    environment.pop(key)
            environment["MACHTELD_PROBE_PIDFILE"] = str(marker)
            observation, elapsed = runner(
                runtime,
                args.solution.resolve(),
                fixture,
                case,
                environment,
                args.outer_timeout,
            )
            pid, marker_error = read_pid(marker)
            cleanup_error = marker_error
            if pid is not None:
                # The contract requires death before run_probe returns. A
                # grace period is used only to make apparatus cleanup polite;
                # it never turns an initially-live child into a passing case.
                state, state_error = process_state(pid)
                if state == "alive":
                    cleanup_error = "direct fixture was still alive when run_probe returned"
                    cleanup_state, _ = wait_for_dead(pid)
                    if cleanup_state == "alive":
                        termination_error = kill_survivor(pid)
                        if termination_error:
                            infrastructure_error = termination_error
                elif state == "unknown":
                    infrastructure_error = state_error or "could not determine fixture process state"
                    termination_error = kill_survivor(pid)
                    if termination_error:
                        infrastructure_error += "; " + termination_error
                else:
                    cleanup_error = None
            if sha256(fixture).lower() != (args.fixture_sha256 or sha256(fixture)).lower():
                infrastructure_error = f"fixture hash changed during case {index}"

            expected = case["expected"]
            values = observation.get("values") if observation.get("status") == "ok" else None
            matches = values == expected
            timely = case["mode"] != "hang" or elapsed < 1.0
            passed = bool(matches and cleanup_error is None and timely)
            reason = None
            if observation.get("status") != "ok":
                reason = observation.get("error", "candidate produced no result")
            elif not matches:
                reason = f"expected {short(expected)}, got {short(values)}"
            elif cleanup_error:
                reason = cleanup_error
            elif not timely:
                reason = f"timeout call returned too slowly ({elapsed:.3f}s including runtime startup)"
            verdicts.append(
                {
                    "id": str(case.get("id", index)),
                    "dimension": str(case.get("dimension", "unspecified")),
                    "passed": passed,
                    "reason": reason,
                    "elapsed_ms": round(elapsed * 1000, 1),
                }
            )
            if infrastructure_error:
                break

    if infrastructure_error:
        print(json.dumps({"infrastructure_error": infrastructure_error}))
        return 2
    if sha256(runtime).lower() != (expected_runtime_hash or sha256(runtime)).lower():
        print(json.dumps({"infrastructure_error": f"runtime hash changed: {runtime}"}))
        return 2

    passed_count = sum(item["passed"] for item in verdicts)
    total = len(cases)
    if args.log:
        append_attempt(args.log, passed_count, total)
    if not args.quiet and passed_count != total:
        first = next(item for item in verdicts if not item["passed"])
        print(f"FAIL case {first['id']}: {first['reason']}")
    if not args.quiet:
        print(f"{'PASS' if passed_count == total else 'FAIL'}  {passed_count}/{total} cases passed")
    summary_cases = [
        {key: item[key] for key in ("id", "dimension", "passed", "reason", "elapsed_ms")}
        for item in verdicts
    ]
    summary = {
        "summary": {
            "passed": passed_count,
            "total": total,
            "all": passed_count == total,
            "cases": summary_cases,
        }
    }
    # ASCII JSON is independent of the Windows console code page. Consumers
    # decode the escapes back to the original Unicode strings.
    print(json.dumps(summary, ensure_ascii=True, separators=(",", ":")))
    return 0 if passed_count == total else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise
    except Exception:
        print(json.dumps({"infrastructure_error": traceback.format_exc()}))
        raise SystemExit(2)
