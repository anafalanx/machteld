#!/usr/bin/env python3
"""Shared, standard-library-only support for the serious experiment harness."""

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
TASK_COUNT = 30
DESIGN = "machteld-vs-python-serious-v1"
MANIFEST_FORMAT = "machteld-serious-run-manifest-v1"
RESULT_FORMAT = "machteld-serious-results-v1"

REQUIRED_TASK_FIELDS = {
    "id",
    "fn",
    "in",
    "out",
    "desc",
    "difficulty",
    "family",
    "tags",
    "visible",
    "hidden",
    "provenance",
}
FAMILIES = {"validator", "number-theory", "bit-encoding", "interpreter"}
DIFFICULTIES = {"mid", "hard", "very-hard"}


class HarnessError(RuntimeError):
    """An apparatus/integrity error, never a solver failure."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_digest(root: Path, files: Iterable[Path]) -> dict[str, Any]:
    ordered = sorted(set(files), key=lambda item: item.relative_to(root).as_posix())
    digest = hashlib.sha256()
    total = 0
    rows: list[dict[str, Any]] = []
    for path in ordered:
        relative = path.relative_to(root).as_posix()
        size = path.stat().st_size
        file_hash = sha256(path)
        total += size
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(size).encode("ascii"))
        digest.update(b"\0")
        digest.update(bytes.fromhex(file_hash))
        rows.append({"path": relative, "bytes": size, "sha256": file_hash})
    return {"sha256": digest.hexdigest(), "files": len(rows), "bytes": total, "entries": rows}


def python_semantic_files(root: Path) -> list[Path]:
    """Files used by an isolated ``python -I -S -B`` standard-library run."""
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
    return sorted(set(selected), key=lambda item: item.relative_to(root).as_posix())


def python_semantic_tree(root: Path, *, include_entries: bool = False) -> dict[str, Any]:
    result = tree_digest(root, python_semantic_files(root))
    result["root"] = str(root.resolve())
    result["policy"] = (
        "top runtime files + DLLs + Lib; excludes __pycache__, site-packages, pyc/pyo"
    )
    if not include_entries:
        result.pop("entries", None)
    return result


def copy_python_runtime(source_root: Path, target_root: Path) -> dict[str, Any]:
    if target_root.exists():
        raise HarnessError(f"refusing to overwrite frozen Python runtime: {target_root}")
    files = python_semantic_files(source_root)
    if not files:
        raise HarnessError(f"no Python semantic runtime files found under {source_root}")
    target_root.mkdir(parents=True)
    for source in files:
        target = target_root / source.relative_to(source_root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    result = python_semantic_tree(target_root)
    result["source_root"] = str(source_root.resolve())
    return result


def _validate_json_shape(value: Any, where: str) -> None:
    if value is None or type(value) in {bool, int, str}:
        return
    if type(value) is float:
        if not math.isfinite(value):
            raise HarnessError(f"{where}: non-finite JSON number")
        return
    if type(value) is list:
        for index, item in enumerate(value):
            _validate_json_shape(item, f"{where}[{index}]")
        return
    if type(value) is dict:
        for key, item in value.items():
            if type(key) is not str:
                raise HarnessError(f"{where}: JSON object key is not a string")
            _validate_json_shape(item, f"{where}.{key}")
        return
    raise HarnessError(f"{where}: unsupported JSON value {type(value).__name__}")


def normalize_expected(expected: Any, outputs: int, where: str) -> str | list[int | str]:
    if expected == "FAIL":
        return "FAIL"
    if outputs == 1 and type(expected) in {int, str}:
        values = [expected]
    elif type(expected) is list and len(expected) == outputs:
        values = expected
    else:
        raise HarnessError(f"{where}: expected must be FAIL or {outputs} output value(s)")
    for index, value in enumerate(values):
        if type(value) not in {int, str}:
            raise HarnessError(
                f"{where}[{index}]: outputs are restricted to exact int or string values"
            )
    return list(values)


def normalize_cases(value: Any, inputs: int, outputs: int, where: str) -> list[dict[str, Any]]:
    if type(value) is not list or not value:
        raise HarnessError(f"{where}: cases must be a nonempty list")
    normalized: list[dict[str, Any]] = []
    for index, raw in enumerate(value):
        label = f"{where}[{index}]"
        if type(raw) is list and len(raw) == 2:
            args, expected = raw
            case_id = f"case-{index + 1:03d}"
            dimension = None
        elif type(raw) is dict:
            args = raw.get("inputs", raw.get("input"))
            expected = raw.get("expected")
            case_id = str(raw.get("id", f"case-{index + 1:03d}"))
            dimension = raw.get("dimension")
        else:
            raise HarnessError(f"{label}: case must be [inputs, expected] or an object")
        if type(args) is not list or len(args) != inputs:
            raise HarnessError(f"{label}: expected exactly {inputs} input argument(s)")
        for arg_index, arg in enumerate(args):
            _validate_json_shape(arg, f"{label}.inputs[{arg_index}]")
        normalized.append(
            {
                "id": case_id,
                "dimension": dimension,
                "inputs": args,
                "expected": normalize_expected(expected, outputs, f"{label}.expected"),
            }
        )
    if len({case["id"] for case in normalized}) != len(normalized):
        raise HarnessError(f"{where}: duplicate case ids")
    return normalized


def load_task(path: Path) -> dict[str, Any]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise HarnessError(f"cannot load task {path}: {exc}") from exc
    if type(raw) is not dict:
        raise HarnessError(f"task must be a JSON object: {path}")
    missing = REQUIRED_TASK_FIELDS - raw.keys()
    if missing:
        raise HarnessError(f"task {path.name} lacks fields: {', '.join(sorted(missing))}")
    if raw["id"] != path.stem or type(raw["id"]) is not str:
        raise HarnessError(f"task id/path mismatch: {path}")
    if type(raw["fn"]) is not str or not raw["fn"]:
        raise HarnessError(f"task {path.name}: invalid fn")
    if type(raw["in"]) is not int or raw["in"] < 0:
        raise HarnessError(f"task {path.name}: invalid input arity")
    if type(raw["out"]) is not int or raw["out"] < 1:
        raise HarnessError(f"task {path.name}: invalid output arity")
    if type(raw["desc"]) is not str or not raw["desc"].strip():
        raise HarnessError(f"task {path.name}: invalid description")
    if raw["family"] not in FAMILIES:
        raise HarnessError(f"task {path.name}: unknown family {raw['family']!r}")
    if raw["difficulty"] not in DIFFICULTIES:
        raise HarnessError(f"task {path.name}: unknown difficulty {raw['difficulty']!r}")
    if type(raw["tags"]) is not list or any(type(tag) is not str for tag in raw["tags"]):
        raise HarnessError(f"task {path.name}: tags must be strings")
    if type(raw["provenance"]) is not dict:
        raise HarnessError(f"task {path.name}: provenance must be an object")
    raw["visible_normalized"] = normalize_cases(
        raw["visible"], raw["in"], raw["out"], f"{path.name}.visible"
    )
    raw["hidden_normalized"] = normalize_cases(
        raw["hidden"], raw["in"], raw["out"], f"{path.name}.hidden"
    )
    raw["source_path"] = str(path.resolve())
    raw["sha256"] = sha256(path)
    return raw


def discover_tasks(corpus: Path = CORPUS, expected_count: int = TASK_COUNT) -> list[dict[str, Any]]:
    paths = sorted(
        path
        for path in corpus.glob("*.json")
        if path.name.lower() != "provenance.json"
    )
    if len(paths) != expected_count:
        raise HarnessError(f"expected {expected_count} task files in {corpus}, found {len(paths)}")
    tasks = [load_task(path) for path in paths]
    if len({task["id"] for task in tasks}) != len(tasks):
        raise HarnessError("duplicate task ids")
    return tasks


def apparatus_files() -> list[Path]:
    """Return every frozen source artifact, excluding generated trial state."""
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
    return sorted(files, key=lambda item: item.relative_to(EXP).as_posix())


def apparatus_hashes() -> dict[str, dict[str, Any]]:
    return {
        path.relative_to(EXP).as_posix(): {"sha256": sha256(path), "bytes": path.stat().st_size}
        for path in apparatus_files()
    }


def verify_hash_map(root: Path, mapping: dict[str, Any], label: str) -> None:
    for relative, record in mapping.items():
        expected = record["sha256"] if type(record) is dict else record
        path = root / relative
        if not path.is_file():
            raise HarnessError(f"{label} missing: {path}")
        if sha256(path).lower() != str(expected).lower():
            raise HarnessError(f"{label} hash mismatch: {path}")


def atomic_write_json(path: Path, value: Any, *, indent: int | None = 2) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(value, ensure_ascii=False, indent=indent)
    if indent is not None:
        text += "\n"
    else:
        text += "\n"
    descriptor, temporary_text = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    temporary = Path(temporary_text)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def make_readonly(path: Path) -> None:
    path.chmod(stat.S_IREAD)


def make_writable(path: Path) -> None:
    try:
        path.chmod(stat.S_IWRITE | stat.S_IREAD)
    except FileNotFoundError:
        pass


def remove_tree_readonly(path: Path) -> None:
    def onerror(function, target, _exc_info) -> None:
        os.chmod(target, stat.S_IWRITE)
        function(target)

    shutil.rmtree(path, onerror=onerror)


def load_manifest(path: Path | None = None) -> dict[str, Any]:
    manifest_path = path or (RUNS / "manifest.json")
    try:
        value = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise HarnessError(f"cannot load manifest {manifest_path}: {exc}") from exc
    if value.get("format") != MANIFEST_FORMAT or value.get("design") != DESIGN:
        raise HarnessError(f"unexpected manifest format/design: {manifest_path}")
    return value


def relative_to_exp(path: Path) -> str:
    return path.resolve().relative_to(EXP.resolve()).as_posix()
