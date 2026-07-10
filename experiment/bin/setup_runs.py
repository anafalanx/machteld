#!/usr/bin/env python3
"""Create opaque per-cell sandboxes for the registered pilot."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import stat
import subprocess
import sys


EXP = Path(__file__).resolve().parents[1]
REPO = EXP.parent
CORPUS = EXP / "corpus"
RUNS = EXP / "runs"
ATTEMPTS = EXP / "attempts"
DEFAULT_TASKS = ("gcd", "sum_ints")
ARMS = {"machteld": "tcl", "python": "py"}
APPARATUS_FILES = (
    "AGENT_PROMPT.md",
    "EXPERIMENT.md",
    "README.md",
    "RUNBOOK.md",
    "SUBJECT_PROTOCOL.md",
    "bin/check.py",
    "bin/grade_runs.py",
    "bin/setup_runs.py",
    "bin/verify_refs.py",
    "corpus/PROVENANCE.md",
    "primers/machteld.md",
    "primers/python.md",
    "refs/machteld/gcd.tcl",
    "refs/machteld/sum_ints.tcl",
    "refs/python/gcd.py",
    "refs/python/sum_ints.py",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _remove_readonly(function, path, _exc_info) -> None:
    os.chmod(path, stat.S_IWRITE)
    function(path)


def remove_generated_runs() -> None:
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
    (RUNS / "manifest.json").unlink(missing_ok=True)
    attempts_root = ATTEMPTS.resolve()
    if attempts_root.parent != EXP.resolve() or attempts_root.name != "attempts":
        raise RuntimeError(f"refusing to clean redirected attempts root: {attempts_root}")
    for path in ATTEMPTS.glob("cell-*.jsonl"):
        resolved = path.resolve()
        if resolved.parent != attempts_root or not path.name.startswith("cell-"):
            raise RuntimeError(f"refusing to remove unexpected attempt log: {path}")
        path.unlink()


def existing_subject_work() -> list[Path]:
    work = [
        path
        for path in RUNS.glob("cell-*/solution.*")
        if path.is_file() and path.stat().st_size > 0
    ]
    work.extend(
        path
        for path in ATTEMPTS.glob("cell-*.jsonl")
        if path.is_file() and path.stat().st_size > 0
    )
    return work


def git_metadata() -> dict:
    def run(*args: str) -> str:
        proc = subprocess.run(
            ["git", *args], cwd=REPO, capture_output=True, text=True, encoding="utf-8"
        )
        return proc.stdout.strip() if proc.returncode == 0 else ""

    return {"head": run("rev-parse", "HEAD"), "status_porcelain": run("status", "--porcelain")}


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
        raise RuntimeError(f"cannot query machteld version: {(proc.stderr or proc.stdout).strip()}")
    return proc.stdout.splitlines()[0].strip()


def task_markdown(task: dict, solution_name: str) -> str:
    rendered = []
    for inputs, expected in task["visible"]:
        shown = expected
        if task["out"] == 1 and expected != "FAIL":
            shown = expected[0]
        rendered.append(
            f"- inputs `{json.dumps(inputs, ensure_ascii=False)}` -> "
            f"output `{json.dumps(shown, ensure_ascii=False)}`"
        )
    examples = "\n".join(rendered)
    result_label = "result" if task["out"] == 1 else "results"
    return f"""# Task: {task['id']}

{task['desc']}

Define **{task['fn']}** taking {task['in']} argument(s) and returning
{task['out']} {result_label}.

Visible examples:

{examples}

Write the solution in `{solution_name}`. Test it with `check.cmd`; the check
command shows visible-case feedback and counts as one iteration. A larger
hidden set is used after you finish, so implement the
specification rather than matching only these examples.
"""


def cmd_wrapper(
    python: Path,
    python_hash: str,
    machteld: Path,
    machteld_hash: str,
    cell_name: str,
    arm: str,
    solution_name: str,
    task: dict,
) -> str:
    return (
        "@echo off\r\n"
        f'set "MACHTELD_BIN={machteld}"\r\n'
        f'"{python}" -B "%~dp0..\\..\\bin\\check.py" '
        f'--arm {arm} --solution "%~dp0{solution_name}" '
        f'--cases "%~dp0visible.json" --fn {task["fn"]} '
        f'--outputs {task["out"]} '
        f'--machteld-sha256 {machteld_hash} --python-sha256 {python_hash} '
        f'--log "%~dp0..\\..\\attempts\\{cell_name}.jsonl"\r\n'
        "exit /b %ERRORLEVEL%\r\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tasks", nargs="+", default=list(DEFAULT_TASKS))
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--seed", type=int, default=20260711)
    parser.add_argument("--force", action="store_true")
    parser.add_argument(
        "--discard-submissions",
        action="store_true",
        help="allow --force to delete nonempty solutions/attempt logs",
    )
    args = parser.parse_args()
    if args.trials < 1:
        parser.error("--trials must be positive")
    if args.discard_submissions and not args.force:
        parser.error("--discard-submissions requires --force")

    task_files = [CORPUS / f"{task_id}.json" for task_id in args.tasks]
    missing = [path for path in task_files if not path.is_file()]
    if missing:
        parser.error("missing corpus task(s): " + ", ".join(str(path) for path in missing))
    try:
        tasks = {path.stem: json.loads(path.read_text(encoding="utf-8")) for path in task_files}
    except (OSError, json.JSONDecodeError) as exc:
        parser.error(f"cannot load corpus: {exc}")
    for task_id in args.tasks:
        task = tasks[task_id]
        required = {"id", "desc", "fn", "in", "out", "tags", "visible", "hidden"}
        if not required.issubset(task) or task["id"] != task_id:
            parser.error(f"invalid corpus task: {task_id}")

    python = Path(sys.executable).resolve()
    if not python.is_file():
        parser.error(f"Python executable not found: {python}")
    python_hash = sha256(python)
    machteld = Path(os.environ.get("MACHTELD_BIN", REPO / "build" / "machteld.exe")).resolve()
    if not machteld.is_file():
        parser.error(f"machteld executable not found: {machteld}")
    machteld_hash = sha256(machteld)
    try:
        machteld_release = machteld_version(machteld)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        parser.error(str(exc))

    prerequisite_files = [EXP / relative for relative in APPARATUS_FILES]
    prerequisite_files.extend(task_files)
    missing = [path for path in prerequisite_files if not path.is_file()]
    if missing:
        parser.error("missing apparatus file(s): " + ", ".join(str(path) for path in missing))
    instructions = (EXP / "AGENT_PROMPT.md").read_text(encoding="utf-8")
    for arm in ARMS:
        (EXP / "primers" / f"{arm}.md").read_text(encoding="utf-8")
    apparatus_hashes = {
        path.relative_to(EXP).as_posix(): sha256(path) for path in prerequisite_files
    }

    cells = [
        {"task": task_id, "arm": arm, "trial": trial}
        for task_id in args.tasks
        for arm in ARMS
        for trial in range(1, args.trials + 1)
    ]
    random.Random(args.seed).shuffle(cells)

    RUNS.mkdir(parents=True, exist_ok=True)
    ATTEMPTS.mkdir(parents=True, exist_ok=True)
    existing = list(RUNS.glob("cell-*"))
    if existing or (RUNS / "manifest.json").exists():
        if not args.force:
            parser.error("generated runs already exist; use --force to replace only cell-* sandboxes")
        subject_work = existing_subject_work()
        if subject_work and not args.discard_submissions:
            parser.error(
                "refusing to discard subject work; archive it or add --discard-submissions: "
                + ", ".join(str(path) for path in subject_work)
            )
        remove_generated_runs()

    manifest: list[dict] = []
    for index, cell in enumerate(cells, 1):
        task = tasks[cell["task"]]
        arm = cell["arm"]
        extension = ARMS[arm]
        solution_name = f"solution.{extension}"
        name = f"cell-{index:03d}"
        directory = RUNS / name
        directory.mkdir()

        primer_source = EXP / "primers" / f"{arm}.md"
        shutil.copyfile(primer_source, directory / "primer.md")
        (directory / "instructions.md").write_text(instructions, encoding="utf-8", newline="\n")
        (directory / "task.md").write_text(
            task_markdown(task, solution_name), encoding="utf-8", newline="\n"
        )
        (directory / "visible.json").write_text(
            json.dumps(task["visible"], ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
            newline="\n",
        )
        (directory / solution_name).write_text("", encoding="utf-8")
        (directory / "check.cmd").write_text(
            cmd_wrapper(
                python,
                python_hash,
                machteld,
                machteld_hash,
                name,
                arm,
                solution_name,
                task,
            ),
            encoding="utf-8",
            newline="",
        )
        public_names = ("instructions.md", "primer.md", "task.md", "visible.json", "check.cmd")
        public_hashes = {filename: sha256(directory / filename) for filename in public_names}
        for filename in public_names:
            (directory / filename).chmod(stat.S_IREAD)
        manifest.append(
            {
                **cell,
                "cell": name,
                "directory": f"runs/{name}",
                "solution": solution_name,
                "fn": task["fn"],
                "outputs": task["out"],
                "tags": task.get("tags", []),
                "primer_sha256": sha256(primer_source),
                "primer_bytes": primer_source.stat().st_size,
                "attempt_log": f"attempts/{name}.jsonl",
                "public_sha256": public_hashes,
            }
        )

    manifest_doc = {
        "design": "machteld-vs-python-micro-pilot-v1",
        "seed": args.seed,
        "trials_per_cell": args.trials,
        "tasks": args.tasks,
        "arms": list(ARMS),
        "python": {"path": str(python), "version": sys.version, "sha256": python_hash},
        "machteld": {
            "path": str(machteld),
            "version": machteld_release,
            "sha256": machteld_hash,
        },
        "apparatus_sha256": apparatus_hashes,
        "git": git_metadata(),
        "cells": manifest,
    }
    (RUNS / "manifest.json").write_text(
        json.dumps(manifest_doc, indent=2) + "\n", encoding="utf-8", newline="\n"
    )
    print(
        f"created {len(cells)} opaque sandboxes: {len(args.tasks)} tasks x "
        f"{len(ARMS)} arms x {args.trials} trials (seed {args.seed})"
    )
    print(f"manifest: {RUNS / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
