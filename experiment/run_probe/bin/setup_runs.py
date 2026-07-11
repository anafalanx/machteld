#!/usr/bin/env python3
"""Create six opaque run_probe subject sandboxes."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shutil
import stat
import subprocess
import sys


EXP = Path(__file__).resolve().parents[1]
REPO = EXP.parents[1]
RUNS = EXP / "runs"
ATTEMPTS = EXP / "attempts"
CASES = EXP / "cases" / "run_probe.json"
FIXTURE = EXP / "fixture" / "process_fixture.exe"
DEFAULT_MACHTELD = EXP / "runtime" / "machteld.exe"
ARMS = {"machteld": "tcl", "python": "py"}
TRIALS_PER_ARM = 3
EXPECTED_MACHTELD_SHA256 = "9f222f33b257849ad9ae11a9a4b97752cac4e8d5d6b7ccc9820563d31380ce51"
EXPECTED_FIXTURE_SHA256 = "5fc03aae68145054d73ff94a51b508c2678ffccf3322fb4f1625518e439f6823"
EXPECTED_PYTHON_SHA256 = "478201058e5eeca3725ce3a6cd115413f67eab4827c82409b87f3b85a632d610"
EXPECTED_PYTHON_TREE_SHA256 = "4f834ca1eb4f7e0b631a7a041201467a13ee2975ece72f1359c00712cd94c1ff"
EXPECTED_CORPUS_SHA256 = "aed99337ce1c2e546664119b1dad651ce3413c71afe078ccd89ab1ee9a7229cf"
APPARATUS_FILES = (
    ".gitignore",
    "AGENT_PROMPT.md",
    "EXPERIMENT.md",
    "INSTRUCTIONS.md",
    "README.md",
    "RUNTIME_LOCK.json",
    "RUNBOOK.md",
    "SUBJECT_PROTOCOL.md",
    "TASK.md",
    "bin/bundle.py",
    "bin/check.py",
    "bin/grade_runs.py",
    "bin/selftest.py",
    "bin/setup_runs.py",
    "bin/verify_refs.py",
    "cases/PROVENANCE.md",
    "cases/run_probe.json",
    "fixture/PROVENANCE.md",
    "fixture/build.cmd",
    "fixture/process_fixture.c",
    "fixture/process_fixture.exe",
    "primers/machteld.md",
    "primers/python.md",
    "refs/machteld/run_probe.tcl",
    "refs/python/run_probe.py",
    "runtime/PROVENANCE.md",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_runtime_lock() -> dict[str, object]:
    path = EXP / "RUNTIME_LOCK.json"
    try:
        lock = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"cannot read runtime lock: {exc}") from exc
    if lock.get("format") != "machteld-run-probe-runtime-lock-v1":
        raise RuntimeError("unexpected runtime-lock format")
    checks = (
        (EXP / lock["machteld"]["relative_path"], lock["machteld"]["sha256"]),
        (EXP / lock["fixture"]["relative_path"], lock["fixture"]["sha256"]),
        (EXP / "fixture" / "process_fixture.c", lock["fixture"]["source_sha256"]),
        (EXP / "fixture" / "build.cmd", lock["fixture"]["build_script_sha256"]),
        (EXP / lock["corpus"]["relative_path"], lock["corpus"]["sha256"]),
    )
    for file_path, expected in checks:
        if not file_path.is_file() or sha256(file_path) != expected:
            raise RuntimeError(f"runtime-lock mismatch: {file_path}")
    if lock["machteld"]["sha256"] != EXPECTED_MACHTELD_SHA256:
        raise RuntimeError("machteld lock differs from frozen design constant")
    if lock["fixture"]["sha256"] != EXPECTED_FIXTURE_SHA256:
        raise RuntimeError("fixture lock differs from frozen design constant")
    if lock["python"]["sha256"] != EXPECTED_PYTHON_SHA256:
        raise RuntimeError("Python lock differs from frozen design constant")
    if lock["python"]["semantic_tree_sha256"] != EXPECTED_PYTHON_TREE_SHA256:
        raise RuntimeError("Python tree lock differs from frozen design constant")
    if lock["corpus"]["sha256"] != EXPECTED_CORPUS_SHA256:
        raise RuntimeError("corpus lock differs from frozen design constant")
    return lock


def python_semantic_files(root: Path) -> list[Path]:
    """Select the isolated runtime files whose exact bytes define this arm."""
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
            relative_parts = path.relative_to(root).parts
            if "__pycache__" in relative_parts or "site-packages" in relative_parts:
                continue
            if path.suffix.lower() in {".pyc", ".pyo"}:
                continue
            selected.append(path)
    return sorted(set(selected), key=lambda item: item.relative_to(root).as_posix())


def python_semantic_tree(root: Path) -> dict[str, object]:
    """Hash the launcher, DLLs, and stdlib used under `-I -S -B`."""
    selected = python_semantic_files(root)
    tree = hashlib.sha256()
    total_bytes = 0
    for path in selected:
        relative = path.relative_to(root).as_posix()
        file_hash = sha256(path)
        size = path.stat().st_size
        total_bytes += size
        tree.update(relative.encode("utf-8"))
        tree.update(b"\0")
        tree.update(str(size).encode("ascii"))
        tree.update(b"\0")
        tree.update(bytes.fromhex(file_hash))
    return {
        "root": str(root),
        "sha256": tree.hexdigest(),
        "files": len(selected),
        "bytes": total_bytes,
        "policy": "top runtime files + DLLs + Lib; excludes __pycache__, site-packages, pyc/pyo",
    }


def git_metadata() -> dict[str, str]:
    def run(*args: str) -> str:
        proc = subprocess.run(
            ["git", *args], cwd=REPO, capture_output=True, text=True, encoding="utf-8"
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"git {' '.join(args)} failed: {(proc.stderr or proc.stdout).strip()}"
            )
        return proc.stdout.strip()

    return {
        "head": run("rev-parse", "HEAD"),
        "status_porcelain": run("status", "--porcelain"),
    }


def machteld_version(executable: Path) -> str:
    proc = subprocess.run(
        [str(executable)],
        input="puts [::machteld::version]\nexit\n",
        cwd=REPO,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=10,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        raise RuntimeError((proc.stderr or proc.stdout or "version query failed").strip())
    return proc.stdout.splitlines()[0].strip()


def _remove_readonly(function, path, _exc_info) -> None:
    os.chmod(path, stat.S_IWRITE)
    function(path)


def existing_subject_work() -> list[Path]:
    work: list[Path] = []
    allowed_names = {
        "instructions.md",
        "primer.md",
        "task.md",
        "visible.json",
        "check.cmd",
        "process fixture.exe",
        "solution.tcl",
        "solution.py",
    }
    manifest_hashes: dict[str, dict[str, str]] = {}
    manifest_path = RUNS / "manifest.json"
    if manifest_path.is_file():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest_hashes = {
                str(cell["cell"]): dict(cell.get("public_sha256", {}))
                for cell in manifest.get("cells", [])
            }
        except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError):
            work.append(manifest_path)
    for directory in RUNS.glob("cell-*"):
        if not directory.is_dir():
            work.append(directory)
            continue
        for path in directory.iterdir():
            if path.name not in allowed_names or path.is_dir():
                work.append(path)
            elif path.name.startswith("solution.") and path.stat().st_size > 0:
                work.append(path)
        for filename, expected in manifest_hashes.get(directory.name, {}).items():
            path = directory / filename
            if not path.is_file() or sha256(path).lower() != expected.lower():
                work.append(path)
    for path in (ATTEMPTS.iterdir() if ATTEMPTS.is_dir() else ()):
        if path.name != ".gitkeep" and (path.is_dir() or path.stat().st_size > 0):
            work.append(path)
    metadata = EXP / "subject-metadata.jsonl"
    if metadata.is_file() and metadata.stat().st_size > 0:
        work.append(metadata)
    return work


def remove_generated_runs(discard_subject_work: bool) -> None:
    root = RUNS.resolve()
    if root.parent != EXP.resolve() or root.name != "runs":
        raise RuntimeError(f"refusing to clean redirected runs root: {root}")
    for path in RUNS.glob("cell-*"):
        resolved = path.resolve()
        if resolved.parent != root or not path.name.startswith("cell-"):
            raise RuntimeError(f"refusing to remove unexpected path: {path}")
        if path.is_dir():
            shutil.rmtree(path, onerror=_remove_readonly)
        else:
            path.chmod(stat.S_IWRITE)
            path.unlink()
    manifest_path = RUNS / "manifest.json"
    if manifest_path.exists():
        manifest_path.chmod(stat.S_IWRITE)
        manifest_path.unlink()

    attempts_root = ATTEMPTS.resolve()
    if attempts_root.parent != EXP.resolve() or attempts_root.name != "attempts":
        raise RuntimeError(f"refusing to clean redirected attempts root: {attempts_root}")
    for path in ATTEMPTS.iterdir():
        if path.name == ".gitkeep":
            continue
        resolved = path.resolve()
        if resolved.parent != attempts_root:
            raise RuntimeError(f"refusing to remove unexpected attempt log: {path}")
        if path.is_dir():
            if not discard_subject_work:
                raise RuntimeError(f"refusing to remove unexpected attempt directory: {path}")
            shutil.rmtree(path, onerror=_remove_readonly)
        else:
            path.unlink()
    metadata = EXP / "subject-metadata.jsonl"
    if metadata.exists():
        if not discard_subject_work and metadata.stat().st_size > 0:
            raise RuntimeError(f"refusing to remove subject metadata: {metadata}")
        metadata.unlink()


def cmd_wrapper(
    python: Path,
    python_hash: str,
    machteld: Path,
    machteld_hash: str,
    fixture_hash: str,
    cell_name: str,
    arm: str,
    solution_name: str,
) -> str:
    return (
        "@echo off\r\n"
        f'set "MACHTELD_BIN={machteld}"\r\n'
        f'"{python}" -I -S -B "%~dp0..\\..\\bin\\check.py" '
        f'--arm {arm} --solution "%~dp0{solution_name}" '
        f'--cases "%~dp0visible.json" --fixture "%~dp0process fixture.exe" '
        f'--machteld-sha256 {machteld_hash} --python-sha256 {python_hash} '
        f'--fixture-sha256 {fixture_hash} '
        f'--log "%~dp0..\\..\\attempts\\{cell_name}.jsonl"\r\n'
        "exit /b %ERRORLEVEL%\r\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=20260711)
    parser.add_argument("--force", action="store_true")
    parser.add_argument(
        "--discard-submissions",
        action="store_true",
        help="allow --force to delete nonempty solutions and attempt logs",
    )
    args = parser.parse_args()
    if args.discard_submissions and not args.force:
        parser.error("--discard-submissions requires --force")

    missing = [EXP / relative for relative in APPARATUS_FILES if not (EXP / relative).is_file()]
    if missing:
        parser.error("missing apparatus file(s): " + ", ".join(str(path) for path in missing))
    try:
        runtime_lock = validate_runtime_lock()
    except (KeyError, TypeError, RuntimeError) as exc:
        parser.error(str(exc))

    try:
        corpus = json.loads(CASES.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        parser.error(f"cannot load cases: {exc}")
    if corpus.get("id") != "run_probe" or not {"visible", "hidden"}.issubset(corpus):
        parser.error("invalid run_probe corpus")
    all_cases = corpus["visible"] + corpus["hidden"]
    case_ids = [case.get("id") for case in all_cases if isinstance(case, dict)]
    if (
        len(corpus["visible"]) != 3
        or len(corpus["hidden"]) != 6
        or len(case_ids) != 9
        or len(set(case_ids)) != 9
        or any(not case.get("dimension") for case in all_cases)
    ):
        parser.error("registered corpus must have 3 visible + 6 hidden unique dimensioned cases")
    if sha256(CASES) != EXPECTED_CORPUS_SHA256:
        parser.error("registered corpus hash differs from RUNTIME_LOCK.json")

    python = Path(sys.executable).resolve()
    python_hash = sha256(python)
    if python_hash != EXPECTED_PYTHON_SHA256:
        parser.error(
            f"wrong Python runtime: {python}; expected SHA-256 {EXPECTED_PYTHON_SHA256}"
        )
    python_tree = python_semantic_tree(Path(sys.base_prefix).resolve())
    if python_tree["sha256"] != EXPECTED_PYTHON_TREE_SHA256:
        parser.error("Python semantic runtime tree differs from RUNTIME_LOCK.json")
    if str(python) != runtime_lock["python"]["path"]:
        parser.error("Python executable path differs from RUNTIME_LOCK.json")
    machteld = DEFAULT_MACHTELD.resolve()
    if not machteld.is_file():
        parser.error(f"frozen machteld executable not found: {machteld}")
    machteld_hash = sha256(machteld)
    if machteld_hash != EXPECTED_MACHTELD_SHA256:
        parser.error(f"frozen machteld hash mismatch: {machteld}")
    fixture_hash = sha256(FIXTURE)
    if fixture_hash != EXPECTED_FIXTURE_SHA256:
        parser.error(f"frozen fixture hash mismatch: {FIXTURE}")
    try:
        machteld_release = machteld_version(machteld)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        parser.error(str(exc))

    apparatus_hashes = {
        relative: sha256(EXP / relative) for relative in APPARATUS_FILES
    }
    cells = [
        {"task": "run_probe", "arm": arm, "trial": trial}
        for arm in ARMS
        for trial in range(1, TRIALS_PER_ARM + 1)
    ]
    random.Random(args.seed).shuffle(cells)

    RUNS.mkdir(parents=True, exist_ok=True)
    ATTEMPTS.mkdir(parents=True, exist_ok=True)
    existing = list(RUNS.glob("cell-*"))
    generated_state = (
        bool(existing)
        or (RUNS / "manifest.json").exists()
        or any(path.name != ".gitkeep" for path in ATTEMPTS.iterdir())
        or (EXP / "subject-metadata.jsonl").exists()
    )
    if generated_state:
        if not args.force:
            parser.error("generated runs already exist; use --force to replace cell-* sandboxes")
        subject_work = existing_subject_work()
        if subject_work and not args.discard_submissions:
            parser.error(
                "refusing to discard subject work; archive it or add --discard-submissions: "
                + ", ".join(str(path) for path in subject_work)
            )
        remove_generated_runs(args.discard_submissions)

    instructions = (EXP / "INSTRUCTIONS.md").read_text(encoding="utf-8")
    task_text = (EXP / "TASK.md").read_text(encoding="utf-8")
    manifest_cells: list[dict[str, object]] = []
    for index, cell in enumerate(cells, 1):
        arm = cell["arm"]
        extension = ARMS[str(arm)]
        solution_name = f"solution.{extension}"
        name = f"cell-{index:03d}"
        directory = RUNS / name
        directory.mkdir()

        primer_source = EXP / "primers" / f"{arm}.md"
        shutil.copyfile(primer_source, directory / "primer.md")
        shutil.copyfile(FIXTURE, directory / "process fixture.exe")
        (directory / "instructions.md").write_text(instructions, encoding="utf-8", newline="\n")
        (directory / "task.md").write_text(
            task_text.replace("{{SOLUTION_FILE}}", solution_name),
            encoding="utf-8",
            newline="\n",
        )
        (directory / "visible.json").write_text(
            json.dumps(corpus["visible"], ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
            newline="\n",
        )
        (directory / solution_name).write_text("", encoding="utf-8", newline="\n")
        (directory / "check.cmd").write_text(
            cmd_wrapper(
                python,
                python_hash,
                machteld,
                machteld_hash,
                fixture_hash,
                name,
                str(arm),
                solution_name,
            ),
            encoding="utf-8",
            newline="",
        )
        public_names = (
            "instructions.md",
            "primer.md",
            "task.md",
            "visible.json",
            "check.cmd",
            "process fixture.exe",
        )
        public_hashes = {filename: sha256(directory / filename) for filename in public_names}
        for filename in public_names:
            (directory / filename).chmod(stat.S_IREAD)
        manifest_cells.append(
            {
                **cell,
                "cell": name,
                "directory": f"runs/{name}",
                "solution": solution_name,
                "fn": "run_probe",
                "primer_sha256": sha256(primer_source),
                "primer_bytes": primer_source.stat().st_size,
                "attempt_log": f"attempts/{name}.jsonl",
                "public_sha256": public_hashes,
            }
        )

    manifest = {
        "design": "machteld-vs-python-run-probe-v1",
        "seed": args.seed,
        "trials_per_arm": TRIALS_PER_ARM,
        "task": "run_probe",
        "arms": list(ARMS),
        "python": {
            "path": str(python),
            "version": sys.version,
            "sha256": python_hash,
            "semantic_tree": python_tree,
            "flags": ["-I", "-S", "-B"],
        },
        "machteld": {
            "path": str(machteld),
            "version": machteld_release,
            "sha256": machteld_hash,
        },
        "fixture": {"path": str(FIXTURE.resolve()), "sha256": fixture_hash},
        "platform": {
            "platform": platform.platform(),
            "windows": platform.win32_ver(),
            "machine": platform.machine(),
        },
        "apparatus_sha256": apparatus_hashes,
        "git": git_metadata(),
        "cells": manifest_cells,
    }
    (RUNS / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    (RUNS / "manifest.json").chmod(stat.S_IREAD)
    print(
        f"created {len(cells)} opaque sandboxes: 1 task x {len(ARMS)} arms x "
        f"{TRIALS_PER_ARM} trials (seed {args.seed})"
    )
    print(f"manifest: {RUNS / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
