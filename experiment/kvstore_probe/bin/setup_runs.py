#!/usr/bin/env python3
"""Create six opaque balanced kvstore cells using the serious run's runtimes."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import random
import shutil
import stat
import subprocess
import sys
from typing import Any

BIN = Path(__file__).resolve().parent
if str(BIN) not in sys.path:
    sys.path.insert(0, str(BIN))

from common import (
    ARMS, ATTEMPTS, DESIGN, EXP, HarnessError, MANIFEST_FORMAT,
    MAX_VISIBLE_CHECKS, PRIMERS, REFS, REPO, RESULTS, RUNS, SEED,
    TRIALS_PER_ARM, apparatus_hashes, atomic_write_json, load_task,
    make_readonly, python_semantic_tree, remove_tree, sha256, verify_hash_map,
    python_complete_tree, python_semantic_files,
)


SERIOUS_RESULTS = EXP.parent / "serious" / "results"


def _git_metadata() -> dict[str, str]:
    def run(*args: str) -> str:
        process = subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True, encoding="utf-8")
        if process.returncode:
            raise HarnessError((process.stderr or process.stdout).strip())
        return process.stdout.strip()
    return {"head": run("rev-parse", "HEAD"), "status_porcelain": run("status", "--porcelain")}


def _generated_entries() -> list[Path]:
    return [] if not RUNS.exists() else [path for path in RUNS.iterdir() if path.name != ".gitkeep"]


def _subject_evidence() -> list[Path]:
    evidence: list[Path] = []
    metadata = EXP / "subject-metadata.jsonl"
    if metadata.is_file() and metadata.stat().st_size:
        evidence.append(metadata)
    for root in (ATTEMPTS, RESULTS):
        if root.is_dir():
            evidence.extend(path for path in root.iterdir() if path.name != ".gitkeep")
    manifest_path = RUNS / "manifest.json"
    seal = RUNS / "manifest.sha256"
    if not manifest_path.is_file() or not seal.is_file() or seal.read_text(encoding="ascii").strip() != sha256(manifest_path):
        return evidence + _generated_entries()
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        verify_hash_map(EXP, manifest["apparatus_sha256"], "apparatus")
        for cell in manifest["cells"]:
            directory = EXP / cell["directory"]
            solution = directory / cell["solution"]
            if solution.is_file() and solution.stat().st_size:
                evidence.append(solution)
            for name, expected in cell["public_sha256"].items():
                path = directory / name
                if not path.is_file() or sha256(path) != expected:
                    evidence.append(path)
    except (KeyError, TypeError, OSError, UnicodeError, json.JSONDecodeError, HarnessError):
        evidence.append(manifest_path)
    return evidence


def _clean_runs() -> None:
    root = RUNS.resolve()
    if root.parent != EXP.resolve() or root.name != "runs":
        raise HarnessError(f"refusing redirected runs root: {root}")
    for path in _generated_entries():
        if path.resolve().parent != root:
            raise HarnessError(f"refusing unexpected generated path: {path}")
        if path.is_dir():
            remove_tree(path)
        else:
            path.chmod(stat.S_IREAD | stat.S_IWRITE)
            path.unlink()


def _load_serious_runtime_lock() -> tuple[Path, Path, dict[str, Any]]:
    lock_path = SERIOUS_RESULTS / "runtime-lock.json"
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise HarnessError(f"completed serious runtime lock is unavailable: {exc}") from exc
    python_root = SERIOUS_RESULTS / "runtimes" / "python"
    python = python_root / "python.exe"
    machteld = SERIOUS_RESULTS / "runtimes" / "machteld.exe"
    if sha256(python) != lock["python"]["sha256"] or sha256(machteld) != lock["machteld"]["sha256"]:
        raise HarnessError("completed serious runtime binary hash mismatch")
    actual_tree = python_semantic_tree(python_root)
    expected_tree = lock["python"]["semantic_tree"]
    for field in ("sha256", "files", "bytes", "policy"):
        if actual_tree.get(field) != expected_tree.get(field):
            raise HarnessError(f"completed serious Python runtime-tree {field} mismatch")
    return python_root, machteld, lock


def _schedule() -> list[dict[str, Any]]:
    rng = random.Random(SEED)
    first = ["machteld", "machteld", "python"]
    if rng.randrange(2):
        first = ["python", "python", "machteld"]
    rng.shuffle(first)
    second = ["python" if arm == "machteld" else "machteld" for arm in first]
    trials = {arm: [1, 2, 3] for arm in ARMS}
    rng.shuffle(trials["machteld"])
    rng.shuffle(trials["python"])
    rows: list[dict[str, Any]] = []
    for wave, arms in enumerate((first, second), 1):
        for position, arm in enumerate(arms, 1):
            trial = trials[arm].pop()
            source = f"{DESIGN}\0{SEED}\0{arm}\0{trial}\0{wave}\0{position}\0{rng.getrandbits(128)}"
            rows.append({"cell": "cell-" + hashlib.sha256(source.encode()).hexdigest()[:16],
                         "task": "kvstore", "arm": arm, "trial": trial,
                         "block": 1, "wave": wave, "wave_position": position})
    if len(rows) != 6 or any(sum(row["arm"] == arm for row in rows) != 3 for arm in ARMS):
        raise HarnessError("internal schedule balance error")
    return rows


def _task_markdown(task: dict[str, Any], solution: str) -> str:
    examples = []
    for case in task["visible_normalized"]:
        examples.append("- inputs `" + json.dumps(case["inputs"], ensure_ascii=False) +
                        "` -> output `" + json.dumps(case["expected"][0], ensure_ascii=False) + "`")
    return f"""# Task: kvstore

{task['desc']}

Define **run** taking one argument and returning one string. An expected `FAIL`
means the procedure/function must raise an error.

Visible examples:

{chr(10).join(examples)}

Write only `{solution}`. Run `check.cmd` for visible feedback. At most
{MAX_VISIBLE_CHECKS} checks are available. Hidden cases are graded afterward.
"""


def _wrapper(cell: str, arm: str, solution: str, python: Path, machteld: Path) -> str:
    return (
        "@echo off\r\n"
        f'"{python}" -I -S -B "{BIN / "check.py"}" --arm {arm} '
        f'--solution "%~dp0{solution}" --cases "%~dp0visible.json" '
        f'--python-runtime "{python}" --machteld-runtime "{machteld}" '
        f'--python-sha256 {sha256(python)} --machteld-sha256 {sha256(machteld)} '
        f'--attempt-root "{ATTEMPTS}" --cell {cell} --max-checks {MAX_VISIBLE_CHECKS}\r\n'
        "exit /b %ERRORLEVEL%\r\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true", help="replace only a hash-valid pristine setup")
    args = parser.parse_args()
    try:
        task = load_task()
        instructions = EXP / "INSTRUCTIONS.md"
        required = [instructions, PRIMERS / "machteld.md", PRIMERS / "python.md",
                    REFS / "machteld" / "kvstore.tcl", REFS / "python" / "kvstore.py"]
        missing = [path for path in required if not path.is_file()]
        if missing:
            raise HarnessError("missing required artifacts: " + ", ".join(str(path) for path in missing))
        source_python_root, source_machteld, serious_lock = _load_serious_runtime_lock()

        generated = _generated_entries()
        if generated:
            if not args.force:
                raise HarnessError("generated runs already exist; use --force only for pristine state")
            evidence = _subject_evidence()
            if evidence:
                raise HarnessError("refusing subject-work loss: " + ", ".join(str(path) for path in evidence[:10]))
            _clean_runs()
        elif args.force:
            raise HarnessError("--force supplied but no generated setup exists")
        metadata = EXP / "subject-metadata.jsonl"
        if metadata.is_file() and metadata.stat().st_size:
            raise HarnessError("subject metadata already exists")
        for root in (ATTEMPTS, RESULTS):
            if root.is_dir() and any(path.name != ".gitkeep" for path in root.iterdir()):
                raise HarnessError(f"generated artifacts already exist: {root}")

        RUNS.mkdir(parents=True, exist_ok=True)
        ATTEMPTS.mkdir(parents=True, exist_ok=True)
        frozen = RUNS / "_frozen"
        frozen.mkdir()
        frozen_python_root = frozen / "python"
        frozen_python_root.mkdir()
        # Copy only the files covered by the inherited serious-run semantic
        # lock.  In particular, do not carry over untracked bytecode caches:
        # Python can read .pyc files even under -B (which only suppresses
        # writes).  The complete-tree lock below then covers every copied file.
        for source in python_semantic_files(source_python_root):
            target = frozen_python_root / source.relative_to(source_python_root)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        frozen_python = frozen_python_root / "python.exe"
        frozen_machteld = frozen / "machteld.exe"
        shutil.copy2(source_machteld, frozen_machteld)
        for path in frozen.rglob("*"):
            if path.is_file():
                make_readonly(path)
        frozen_tree = python_semantic_tree(frozen_python_root)
        for field in ("sha256", "files", "bytes", "policy"):
            if frozen_tree[field] != serious_lock["python"]["semantic_tree"][field]:
                raise HarnessError(f"copied Python runtime-tree {field} mismatch")
        frozen_complete_tree = python_complete_tree(frozen_python_root)
        for field in ("sha256", "files", "bytes"):
            if frozen_complete_tree[field] != frozen_tree[field]:
                raise HarnessError(f"frozen Python contains an unlocked file ({field} mismatch)")

        hashes = apparatus_hashes()
        instructions_text = instructions.read_text(encoding="utf-8")
        cells: list[dict[str, Any]] = []
        for row in _schedule():
            arm = row["arm"]
            solution = "solution." + ARMS[arm]
            directory = RUNS / row["cell"]
            directory.mkdir()
            shutil.copyfile(PRIMERS / f"{arm}.md", directory / "primer.md")
            (directory / "instructions.md").write_text(instructions_text, encoding="utf-8", newline="\n")
            (directory / "task.md").write_text(_task_markdown(task, solution), encoding="utf-8", newline="\n")
            (directory / "visible.json").write_text(json.dumps(task["visible"], ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
            (directory / solution).write_text("", encoding="utf-8", newline="\n")
            (directory / "check.cmd").write_text(_wrapper(row["cell"], arm, solution, frozen_python.resolve(), frozen_machteld.resolve()), encoding="utf-8", newline="")
            public = ("instructions.md", "primer.md", "task.md", "visible.json", "check.cmd")
            public_hashes = {name: sha256(directory / name) for name in public}
            for name in public:
                make_readonly(directory / name)
            cells.append({**row, "directory": directory.relative_to(EXP).as_posix(), "solution": solution,
                          "task_sha256": task["sha256"], "public_sha256": public_hashes,
                          "attempt_directory": f"attempts/{row['cell']}"})

        template_path = RUNS / "subject-metadata-template.jsonl"
        template_rows = [{"cell": cell["cell"], "wave": cell["wave"], "agent_id": None,
                          "model_family": None, "started_utc": None, "ended_utc": None,
                          "status": None, "valid": None, "exclusion": None, "note": ""} for cell in cells]
        template_path.write_text("".join(json.dumps(row, separators=(",", ":")) + "\n" for row in template_rows), encoding="utf-8", newline="\n")
        make_readonly(template_path)
        manifest = {
            "format": MANIFEST_FORMAT, "design": DESIGN, "seed": SEED, "task": "kvstore",
            "task_sha256": task["sha256"], "visible_cases": len(task["visible_normalized"]),
            "hidden_cases": len(task["hidden_normalized"]), "arms": list(ARMS),
            "trials_per_arm": TRIALS_PER_ARM, "max_visible_checks": MAX_VISIBLE_CHECKS,
            "schedule": "one six-cell block in two adjacent three-subject waves; 3:3 arm balance",
            "runtime_provenance": {"source_experiment": "serious/results", "source_lock_sha256": sha256(SERIOUS_RESULTS / "runtime-lock.json")},
            "python": {"frozen_executable": frozen_python.relative_to(EXP).as_posix(),
                       "frozen_root": frozen_python_root.relative_to(EXP).as_posix(),
                       "sha256": sha256(frozen_python), "version": serious_lock["python"]["version"],
                       "semantic_tree": frozen_tree, "complete_tree": frozen_complete_tree,
                       "flags": ["-I", "-S", "-B"]},
            "machteld": {"frozen_executable": frozen_machteld.relative_to(EXP).as_posix(),
                         "sha256": sha256(frozen_machteld), "version": serious_lock["machteld"]["version"]},
            "platform": {"platform": platform.platform(), "machine": platform.machine()},
            "apparatus_sha256": hashes,
            "metadata_template": {"path": template_path.relative_to(EXP).as_posix(), "sha256": sha256(template_path)},
            "git": _git_metadata(),
            "waves": [{"wave": wave, "cells": [cell["cell"] for cell in sorted(cells, key=lambda c: c["wave_position"]) if cell["wave"] == wave],
                       "arms": [cell["arm"] for cell in sorted(cells, key=lambda c: c["wave_position"]) if cell["wave"] == wave]} for wave in (1, 2)],
            "cells": cells,
        }
        manifest_path = RUNS / "manifest.json"
        atomic_write_json(manifest_path, manifest)
        (RUNS / "manifest.sha256").write_text(sha256(manifest_path) + "\n", encoding="ascii", newline="\n")
        make_readonly(manifest_path); make_readonly(RUNS / "manifest.sha256")
        print("created 6 opaque cells: kvstore x 2 arms x 3 trials in 2 waves")
        print(f"manifest sha256: {sha256(manifest_path)}")
        return 0
    except (HarnessError, OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as exc:
        parser.error(str(exc))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
