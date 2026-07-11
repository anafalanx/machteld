#!/usr/bin/env python3
"""Shared, standard-library-only support for the kvstore supplement."""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import stat
import tempfile
from typing import Any, Iterable


BIN = Path(__file__).resolve().parent
EXP = BIN.parent
REPO = EXP.parents[1]
CORPUS = EXP / "corpus"
REFS = EXP / "refs"
PRIMERS = EXP / "primers"
RUNS = EXP / "runs"
ATTEMPTS = EXP / "attempts"
RESULTS = EXP / "results"

ARMS = {"machteld": "tcl", "python": "py"}
TRIALS_PER_ARM = 3
MAX_VISIBLE_CHECKS = 8
VISIBLE_CASES = 3
HIDDEN_CASES = 59
SEED = 20260711
DESIGN = "machteld-vs-python-kvstore-supplement-v1"
MANIFEST_FORMAT = "machteld-kvstore-run-manifest-v1"
RESULT_FORMAT = "machteld-kvstore-results-v1"


class HarnessError(RuntimeError):
    """An apparatus/integrity error, never a solver failure."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_digest(root: Path, files: Iterable[Path]) -> dict[str, Any]:
    ordered = sorted(set(files), key=lambda p: p.relative_to(root).as_posix())
    digest = hashlib.sha256()
    rows: list[dict[str, Any]] = []
    total = 0
    for path in ordered:
        relative = path.relative_to(root).as_posix()
        size = path.stat().st_size
        file_hash = sha256(path)
        total += size
        digest.update(relative.encode("utf-8") + b"\0")
        digest.update(str(size).encode("ascii") + b"\0")
        digest.update(bytes.fromhex(file_hash))
        rows.append({"path": relative, "bytes": size, "sha256": file_hash})
    return {"sha256": digest.hexdigest(), "files": len(rows), "bytes": total, "entries": rows}


def python_semantic_files(root: Path) -> list[Path]:
    selected: list[Path] = []
    top_names = {"LICENSE.txt", "BUILD", "pyvenv.cfg"}
    top_suffixes = {".exe", ".dll", ".zip", ".pth", "._pth"}
    for path in root.iterdir():
        if path.is_file() and (path.name in top_names or path.suffix.lower() in top_suffixes):
            selected.append(path)
    for subtree in (root / "DLLs", root / "Lib"):
        if not subtree.is_dir():
            continue
        for path in subtree.rglob("*"):
            if not path.is_file():
                continue
            parts = path.relative_to(root).parts
            if "__pycache__" in parts or "site-packages" in parts:
                continue
            if path.suffix.lower() in {".pyc", ".pyo"}:
                continue
            selected.append(path)
    return sorted(set(selected), key=lambda p: p.relative_to(root).as_posix())


def python_semantic_tree(root: Path) -> dict[str, Any]:
    result = tree_digest(root, python_semantic_files(root))
    result.pop("entries", None)
    result["root"] = str(root.resolve())
    result["policy"] = "top runtime files + DLLs + Lib; excludes __pycache__, site-packages, pyc/pyo"
    return result


def python_complete_tree(root: Path) -> dict[str, Any]:
    """Hash every regular file in a frozen Python runtime, without exclusions."""
    result = tree_digest(root, (path for path in root.rglob("*") if path.is_file()))
    result.pop("entries", None)
    result["root"] = str(root.resolve())
    result["policy"] = "all regular files recursively; no exclusions"
    return result


def _json_value(value: Any, where: str) -> None:
    if value is None or type(value) in {bool, int, str}:
        return
    if type(value) is float and math.isfinite(value):
        return
    if type(value) is list:
        for index, item in enumerate(value):
            _json_value(item, f"{where}[{index}]")
        return
    if type(value) is dict and all(type(key) is str for key in value):
        for key, item in value.items():
            _json_value(item, f"{where}.{key}")
        return
    raise HarnessError(f"{where}: unsupported JSON value")


def normalize_cases(raw: Any, where: str) -> list[dict[str, Any]]:
    if type(raw) is not list or not raw:
        raise HarnessError(f"{where}: expected a nonempty list")
    result: list[dict[str, Any]] = []
    for index, item in enumerate(raw, 1):
        if type(item) is list and len(item) == 2:
            arguments, expected = item
            case_id = f"case-{index:03d}"
        elif type(item) is dict:
            arguments = item.get("inputs", item.get("input"))
            expected = item.get("expected")
            case_id = str(item.get("id", f"case-{index:03d}"))
        else:
            raise HarnessError(f"{where}[{index - 1}]: malformed case")
        if type(arguments) is not list or len(arguments) != 1:
            raise HarnessError(f"{where}[{index - 1}]: expected one argument")
        _json_value(arguments[0], f"{where}[{index - 1}].inputs[0]")
        if expected == "FAIL":
            normalized_expected: str | list[str] = "FAIL"
        elif type(expected) is list and len(expected) == 1 and type(expected[0]) is str:
            normalized_expected = expected
        elif type(expected) is str:
            normalized_expected = [expected]
        else:
            raise HarnessError(f"{where}[{index - 1}]: expected one string or FAIL")
        result.append({"id": case_id, "inputs": arguments, "expected": normalized_expected})
    if len({row["id"] for row in result}) != len(result):
        raise HarnessError(f"{where}: duplicate case ids")
    return result


def task_path(corpus: Path = CORPUS) -> Path:
    candidates = [corpus / "kvstore.json", corpus / "task.json"]
    found = [path for path in candidates if path.is_file()]
    if len(found) != 1:
        raise HarnessError(f"expected exactly one kvstore task at {candidates}")
    return found[0]


def load_task(corpus: Path = CORPUS) -> dict[str, Any]:
    path = task_path(corpus)
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise HarnessError(f"cannot load task {path}: {exc}") from exc
    if type(raw) is not dict:
        raise HarnessError("task must be an object")
    for field in ("id", "desc", "fn", "in", "out", "visible", "hidden"):
        if field not in raw:
            raise HarnessError(f"task lacks {field}")
    if raw["id"] != "kvstore" or raw["fn"] != "run" or raw["in"] != 1 or raw["out"] != 1:
        raise HarnessError("task identity/signature differs from frozen kvstore design")
    if type(raw["desc"]) is not str or not raw["desc"].strip():
        raise HarnessError("task description is empty")
    raw["visible_normalized"] = normalize_cases(raw["visible"], "visible")
    raw["hidden_normalized"] = normalize_cases(raw["hidden"], "hidden")
    if len(raw["visible_normalized"]) != VISIBLE_CASES:
        raise HarnessError(f"frozen design requires {VISIBLE_CASES} visible cases")
    if len(raw["hidden_normalized"]) != HIDDEN_CASES:
        raise HarnessError(f"frozen design requires {HIDDEN_CASES} hidden cases")
    raw["path"] = str(path.resolve())
    raw["sha256"] = sha256(path)
    return raw


def apparatus_files() -> list[Path]:
    excluded_roots = {"runs", "attempts", "results"}
    excluded_names = {"subject-metadata.jsonl"}
    files: list[Path] = []
    for path in EXP.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(EXP)
        if relative.parts[0] in excluded_roots or relative.as_posix() in excluded_names:
            continue
        if "__pycache__" in relative.parts or path.suffix.lower() in {".pyc", ".pyo"}:
            continue
        files.append(path)
    return sorted(files, key=lambda p: p.relative_to(EXP).as_posix())


def apparatus_hashes() -> dict[str, dict[str, Any]]:
    return {
        path.relative_to(EXP).as_posix(): {"sha256": sha256(path), "bytes": path.stat().st_size}
        for path in apparatus_files()
    }


def verify_hash_map(root: Path, mapping: dict[str, Any], label: str) -> None:
    for relative, record in mapping.items():
        path = root / relative
        expected = record["sha256"] if type(record) is dict else record
        if not path.is_file() or sha256(path) != expected:
            raise HarnessError(f"{label} missing or hash-mismatched: {path}")


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def make_readonly(path: Path) -> None:
    path.chmod(stat.S_IREAD)


def remove_tree(path: Path) -> None:
    def onerror(function, target, _exc) -> None:
        os.chmod(target, stat.S_IWRITE)
        function(target)
    shutil.rmtree(path, onerror=onerror)


def load_manifest(path: Path | None = None) -> dict[str, Any]:
    target = path or RUNS / "manifest.json"
    try:
        value = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise HarnessError(f"cannot load manifest {target}: {exc}") from exc
    if value.get("format") != MANIFEST_FORMAT or value.get("design") != DESIGN:
        raise HarnessError("unexpected manifest format/design")
    return value
