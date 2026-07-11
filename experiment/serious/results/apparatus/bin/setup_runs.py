#!/usr/bin/env python3
"""Freeze runtimes and create 180 opaque, balanced subject cells."""

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
from typing import Any

BIN = Path(__file__).resolve().parent
if str(BIN) not in sys.path:
    sys.path.insert(0, str(BIN))

from common import (
    ARMS,
    ATTEMPTS,
    DESIGN,
    EXP,
    HarnessError,
    MANIFEST_FORMAT,
    MAX_VISIBLE_CHECKS,
    PRIMERS,
    REPO,
    RESULTS,
    RUNS,
    TASK_COUNT,
    TRIALS_PER_ARM,
    apparatus_hashes,
    atomic_write_json,
    copy_python_runtime,
    discover_tasks,
    make_readonly,
    remove_tree_readonly,
    sha256,
    verify_hash_map,
)


DEFAULT_SEED = 20260711


def git_metadata() -> dict[str, str]:
    def run(*arguments: str) -> str:
        process = subprocess.run(
            ["git", *arguments],
            cwd=REPO,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        if process.returncode != 0:
            raise HarnessError(
                f"git {' '.join(arguments)} failed: {(process.stderr or process.stdout).strip()}"
            )
        return process.stdout.strip()

    return {"head": run("rev-parse", "HEAD"), "status_porcelain": run("status", "--porcelain")}


def machteld_version(executable: Path) -> str:
    process = subprocess.run(
        [str(executable)],
        input="puts [::machteld::version]\nexit\n",
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=10,
        cwd=REPO,
    )
    if process.returncode != 0 or not process.stdout.strip():
        raise HarnessError((process.stderr or process.stdout or "version query failed").strip())
    return process.stdout.splitlines()[0].strip()


def default_machteld() -> Path:
    candidates = (
        EXP / "runtime" / "machteld.exe",
        EXP.parent / "run_probe" / "runtime" / "machteld.exe",
        REPO / "build" / "machteld.exe",
    )
    return next((path for path in candidates if path.is_file()), candidates[0])


def _generated_entries() -> list[Path]:
    if not RUNS.exists():
        return []
    allowed = {".gitkeep"}
    return [path for path in RUNS.iterdir() if path.name not in allowed]


def _has_subject_work() -> list[Path]:
    evidence: list[Path] = []
    metadata = EXP / "subject-metadata.jsonl"
    if metadata.is_file() and metadata.stat().st_size:
        evidence.append(metadata)
    if RESULTS.is_dir():
        evidence.extend(path for path in RESULTS.iterdir() if path.name != ".gitkeep")
    if ATTEMPTS.is_dir():
        evidence.extend(path for path in ATTEMPTS.iterdir() if path.name != ".gitkeep")
    manifest_path = RUNS / "manifest.json"
    seal_path = RUNS / "manifest.sha256"
    if not manifest_path.is_file() or not seal_path.is_file():
        if _generated_entries():
            evidence.extend(_generated_entries())
        return evidence
    try:
        if seal_path.read_text(encoding="ascii").strip() != sha256(manifest_path):
            return evidence + [manifest_path]
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        for cell in manifest["cells"]:
            directory = EXP / cell["directory"]
            solution = directory / cell["solution"]
            if solution.is_file() and solution.stat().st_size:
                evidence.append(solution)
            for filename, record in cell["public_sha256"].items():
                path = directory / filename
                if not path.is_file() or sha256(path) != record:
                    evidence.append(path)
        verify_hash_map(EXP, manifest["apparatus_sha256"], "apparatus")
    except (KeyError, TypeError, OSError, UnicodeError, json.JSONDecodeError, HarnessError):
        evidence.append(manifest_path)
    return evidence


def _clean_pristine_generated() -> None:
    root = RUNS.resolve()
    if root.parent != EXP.resolve() or root.name != "runs":
        raise HarnessError(f"refusing redirected runs root: {root}")
    for path in _generated_entries():
        resolved = path.resolve()
        if resolved.parent != root:
            raise HarnessError(f"refusing unexpected generated path: {path}")
        if path.is_dir():
            remove_tree_readonly(path)
        else:
            path.chmod(stat.S_IWRITE | stat.S_IREAD)
            path.unlink()


def _task_markdown(task: dict[str, Any], solution_name: str) -> str:
    examples: list[str] = []
    for case in task["visible_normalized"]:
        expected: Any = case["expected"]
        if expected != "FAIL" and task["out"] == 1:
            expected = expected[0]
        examples.append(
            "- inputs `"
            + json.dumps(case["inputs"], ensure_ascii=False)
            + "` -> output `"
            + json.dumps(expected, ensure_ascii=False)
            + "`"
        )
    output_word = "value" if task["out"] == 1 else "values"
    return f"""# Task: {task['id']}

{task['desc']}

Define **{task['fn']}** taking exactly {task['in']} argument(s) and returning
{task['out']} {output_word}. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

{chr(10).join(examples)}

Write only `{solution_name}`. Run `check.cmd` for visible feedback. At most
{MAX_VISIBLE_CHECKS} checks are available. Hidden cases are graded after the
trial, so implement the full specification.
"""


def _cmd_wrapper(
    *,
    python: Path,
    python_hash: str,
    machteld: Path,
    machteld_hash: str,
    cell: str,
    arm: str,
    solution: str,
    task: dict[str, Any],
) -> str:
    check = EXP / "bin" / "check.py"
    return (
        "@echo off\r\n"
        f'"{python}" -I -S -B "{check}" '
        f'--arm {arm} --solution "%~dp0{solution}" --cases "%~dp0visible.json" '
        f'--fn "{task["fn"]}" --inputs {task["in"]} --outputs {task["out"]} '
        f'--python-runtime "{python}" --machteld-runtime "{machteld}" '
        f'--python-sha256 {python_hash} --machteld-sha256 {machteld_hash} '
        f'--attempt-root "{ATTEMPTS}" --cell {cell} --max-checks {MAX_VISIBLE_CHECKS}\r\n'
        "exit /b %ERRORLEVEL%\r\n"
    )


def _schedule(tasks: list[dict[str, Any]], seed: int) -> list[dict[str, Any]]:
    """Two adjacent three-subject waves per task, balanced 3:3 across the block."""
    rng = random.Random(seed)
    ordered = list(tasks)
    rng.shuffle(ordered)
    rows: list[dict[str, Any]] = []
    seen_names: set[str] = set()
    for block, task in enumerate(ordered, 1):
        first = ["machteld", "machteld", "python"]
        if rng.randrange(2):
            first = ["python", "python", "machteld"]
        second = ["python" if arm == "machteld" else "machteld" for arm in first]
        rng.shuffle(first)
        rng.shuffle(second)
        trials = {"machteld": list(range(1, TRIALS_PER_ARM + 1)), "python": list(range(1, TRIALS_PER_ARM + 1))}
        rng.shuffle(trials["machteld"])
        rng.shuffle(trials["python"])
        for wave_offset, arms in enumerate((first, second)):
            wave = 2 * block - 1 + wave_offset
            for position, arm in enumerate(arms, 1):
                trial = trials[arm].pop()
                token_source = f"{seed}\0{task['id']}\0{arm}\0{trial}\0{wave}\0{position}\0{rng.getrandbits(128)}"
                token = hashlib.sha256(token_source.encode("utf-8")).hexdigest()[:16]
                name = "cell-" + token
                if name in seen_names:
                    raise HarnessError("opaque cell-id collision")
                seen_names.add(name)
                rows.append(
                    {
                        "cell": name,
                        "task": task["id"],
                        "arm": arm,
                        "trial": trial,
                        "block": block,
                        "wave": wave,
                        "wave_position": position,
                    }
                )
    if len(rows) != TASK_COUNT * len(ARMS) * TRIALS_PER_ARM:
        raise HarnessError("internal schedule-size error")
    for block in range(1, TASK_COUNT + 1):
        selected = [row for row in rows if row["block"] == block]
        if len(selected) != 6 or {row["arm"] for row in selected} != set(ARMS):
            raise HarnessError(f"unbalanced schedule block {block}")
        if any(sum(row["arm"] == arm for row in selected) != 3 for arm in ARMS):
            raise HarnessError(f"unbalanced arm count in block {block}")
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--machteld", type=Path, default=default_machteld())
    parser.add_argument(
        "--force",
        action="store_true",
        help="replace only a hash-valid pristine setup; subject work is never deleted",
    )
    args = parser.parse_args()
    try:
        if args.seed != DEFAULT_SEED:
            raise HarnessError(
                f"{DESIGN} seed is frozen at {DEFAULT_SEED}; a different seed requires a new design id"
            )
        tasks = discover_tasks()
        instructions_path = EXP / "INSTRUCTIONS.md"
        required = [
            instructions_path,
            PRIMERS / "machteld.md",
            PRIMERS / "python.md",
            *(EXP / "refs" / arm / f"{task['id']}.{ARMS[arm]}" for task in tasks for arm in ARMS),
        ]
        missing = [path for path in required if not path.is_file()]
        if missing:
            raise HarnessError("missing required artifacts: " + ", ".join(str(path) for path in missing))
        source_machteld = args.machteld.resolve()
        if not source_machteld.is_file():
            raise HarnessError(f"machteld runtime not found: {source_machteld}")
        source_python = Path(sys.executable).resolve()
        source_python_root = Path(sys.base_prefix).resolve()
        if not source_python.is_file() or not source_python.is_relative_to(source_python_root):
            raise HarnessError("current Python executable is not under sys.base_prefix")

        generated = _generated_entries()
        if generated:
            if not args.force:
                raise HarnessError("generated runs already exist; use --force only for pristine state")
            evidence = _has_subject_work()
            if evidence:
                raise HarnessError(
                    "refusing subject-work loss; archive state first: "
                    + ", ".join(str(path) for path in evidence[:20])
                )
            _clean_pristine_generated()
        elif args.force:
            raise HarnessError("--force supplied but no generated setup exists")
        if (EXP / "subject-metadata.jsonl").exists() and (EXP / "subject-metadata.jsonl").stat().st_size:
            raise HarnessError("subject metadata already exists")
        if ATTEMPTS.is_dir() and any(path.name != ".gitkeep" for path in ATTEMPTS.iterdir()):
            raise HarnessError("attempt artifacts already exist")
        if RESULTS.is_dir() and any(path.name != ".gitkeep" for path in RESULTS.iterdir()):
            raise HarnessError("result artifacts already exist")

        RUNS.mkdir(parents=True, exist_ok=True)
        ATTEMPTS.mkdir(parents=True, exist_ok=True)
        frozen = RUNS / "_frozen"
        frozen.mkdir()
        frozen_machteld = frozen / "machteld.exe"
        shutil.copy2(source_machteld, frozen_machteld)
        machteld_hash = sha256(frozen_machteld)
        frozen_python_root = frozen / "python"
        python_tree = copy_python_runtime(source_python_root, frozen_python_root)
        relative_executable = source_python.relative_to(source_python_root)
        frozen_python = frozen_python_root / relative_executable
        if not frozen_python.is_file():
            raise HarnessError(f"frozen Python launcher missing: {frozen_python}")
        python_hash = sha256(frozen_python)
        for path in frozen.rglob("*"):
            if path.is_file():
                make_readonly(path)

        hashes = apparatus_hashes()
        instructions = instructions_path.read_text(encoding="utf-8")
        schedule = _schedule(tasks, args.seed)
        task_by_id = {task["id"]: task for task in tasks}
        manifest_cells: list[dict[str, Any]] = []
        for row in schedule:
            task = task_by_id[row["task"]]
            arm = row["arm"]
            solution_name = "solution." + ARMS[arm]
            directory = RUNS / row["cell"]
            directory.mkdir()
            primer = PRIMERS / f"{arm}.md"
            shutil.copyfile(primer, directory / "primer.md")
            (directory / "instructions.md").write_text(instructions, encoding="utf-8", newline="\n")
            (directory / "task.md").write_text(
                _task_markdown(task, solution_name), encoding="utf-8", newline="\n"
            )
            (directory / "visible.json").write_text(
                json.dumps(task["visible"], ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
                newline="\n",
            )
            (directory / solution_name).write_text("", encoding="utf-8", newline="\n")
            (directory / "check.cmd").write_text(
                _cmd_wrapper(
                    python=frozen_python.resolve(),
                    python_hash=python_hash,
                    machteld=frozen_machteld.resolve(),
                    machteld_hash=machteld_hash,
                    cell=row["cell"],
                    arm=arm,
                    solution=solution_name,
                    task=task,
                ),
                encoding="utf-8",
                newline="",
            )
            public_names = ("instructions.md", "primer.md", "task.md", "visible.json", "check.cmd")
            public_hashes = {name: sha256(directory / name) for name in public_names}
            for name in public_names:
                make_readonly(directory / name)
            manifest_cells.append(
                {
                    **row,
                    "directory": directory.relative_to(EXP).as_posix(),
                    "solution": solution_name,
                    "fn": task["fn"],
                    "inputs": task["in"],
                    "outputs": task["out"],
                    "family": task["family"],
                    "difficulty": task["difficulty"],
                    "task_sha256": task["sha256"],
                    "primer_sha256": sha256(primer),
                    "public_sha256": public_hashes,
                    "attempt_directory": f"attempts/{row['cell']}",
                }
            )

        metadata_template = [
            {
                "cell": cell["cell"],
                "wave": cell["wave"],
                "agent_id": None,
                "model_family": None,
                "started_utc": None,
                "ended_utc": None,
                "status": None,
                "valid": None,
                "exclusion": None,
                "note": "",
            }
            for cell in manifest_cells
        ]
        template_path = RUNS / "subject-metadata-template.jsonl"
        template_path.write_text(
            "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in metadata_template),
            encoding="utf-8",
            newline="\n",
        )
        make_readonly(template_path)

        manifest = {
            "format": MANIFEST_FORMAT,
            "design": DESIGN,
            "seed": args.seed,
            "tasks": [task["id"] for task in tasks],
            "task_count": len(tasks),
            "arms": list(ARMS),
            "trials_per_task_arm": TRIALS_PER_ARM,
            "max_visible_checks": MAX_VISIBLE_CHECKS,
            "schedule": "one task per two adjacent three-subject waves; 3:3 arm balance",
            "python": {
                "source_executable": str(source_python),
                "source_root": str(source_python_root),
                "frozen_executable": frozen_python.relative_to(EXP).as_posix(),
                "frozen_root": frozen_python_root.relative_to(EXP).as_posix(),
                "sha256": python_hash,
                "version": sys.version,
                "semantic_tree": python_tree,
                "flags": ["-I", "-S", "-B"],
            },
            "machteld": {
                "source": str(source_machteld),
                "frozen_executable": frozen_machteld.relative_to(EXP).as_posix(),
                "sha256": machteld_hash,
                "version": machteld_version(frozen_machteld),
            },
            "platform": {
                "platform": platform.platform(),
                "windows": platform.win32_ver(),
                "machine": platform.machine(),
            },
            "apparatus_sha256": hashes,
            "metadata_template": {
                "path": template_path.relative_to(EXP).as_posix(),
                "sha256": sha256(template_path),
            },
            "git": git_metadata(),
            "waves": [
                {
                    "wave": wave,
                    "block": min(cell["block"] for cell in manifest_cells if cell["wave"] == wave),
                    "task": next(cell["task"] for cell in manifest_cells if cell["wave"] == wave),
                    "cells": [
                        cell["cell"]
                        for cell in sorted(manifest_cells, key=lambda item: item["wave_position"])
                        if cell["wave"] == wave
                    ],
                    "arms": [
                        cell["arm"]
                        for cell in sorted(manifest_cells, key=lambda item: item["wave_position"])
                        if cell["wave"] == wave
                    ],
                }
                for wave in range(1, TASK_COUNT * 2 + 1)
            ],
            "cells": manifest_cells,
        }
        manifest_path = RUNS / "manifest.json"
        atomic_write_json(manifest_path, manifest)
        seal_path = RUNS / "manifest.sha256"
        seal_path.write_text(sha256(manifest_path) + "\n", encoding="ascii", newline="\n")
        make_readonly(manifest_path)
        make_readonly(seal_path)
        print(
            f"created {len(manifest_cells)} opaque cells: {len(tasks)} tasks x "
            f"{len(ARMS)} arms x {TRIALS_PER_ARM} trials in {TASK_COUNT * 2} waves"
        )
        print(f"manifest: {manifest_path}")
        print(f"manifest sha256: {sha256(manifest_path)}")
        return 0
    except (HarnessError, OSError, UnicodeError, json.JSONDecodeError, subprocess.TimeoutExpired) as exc:
        parser.error(str(exc))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
