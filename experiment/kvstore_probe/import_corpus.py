#!/usr/bin/env python3
"""Deterministically import the full Luax kvstore task without its Luax arm.

The visible and hidden arrays are copied as JSON values without selection,
reordering, augmentation, or expected-output changes.  The only prose edit
replaces the source task's two-sentence Luax/Python-specific error-signalling
block with behaviorally identical neutral wording.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re


EXP = Path(__file__).resolve().parent
WORKSPACE = EXP.parents[2]
SOURCE = WORKSPACE / "_luax" / "experiment" / "tasks" / "kvstore.json"
SOURCE_FUZZER = WORKSPACE / "_luax" / "experiment" / "bin" / "fuzz_kvstore.py"
SOURCE_RETROSPECTIVE = WORKSPACE / "_luax" / "RETROSPECTIVE.md"
TASK_OUT = EXP / "corpus" / "kvstore.json"
PROVENANCE_OUT = EXP / "corpus" / "provenance.json"
PYTHON_REF_OUT = EXP / "refs" / "python" / "kvstore.py"

SOURCE_SENTENCE = (
    "This is a fallible operation: in luax it is written with a `: string!` "
    "return type and signals the malformed case with `fail(...)`; in Python "
    "it raises (ValueError). A failure test case expects the call to fail/raise, "
    "written as the marker \"FAIL\" in place of the expected-outputs list."
)
NEUTRAL_SENTENCE = (
    "This is a fallible operation: a malformed command must make the call raise "
    "an error. A failure test case expects the call to fail, written as the marker "
    "\"FAIL\" in place of the expected-outputs list."
)


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def text_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def value_hash(value: object) -> str:
    encoded = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def main() -> None:
    source = json.loads(SOURCE.read_text(encoding="utf-8"))
    assert source["id"] == "kvstore"
    assert source["fn"] == "run" and source["in"] == 1 and source["out"] == 1
    assert len(source["visible"]) == 3
    assert len(source["hidden"]) == 59
    assert sum(case[1] == "FAIL" for case in source["visible"]) == 0
    assert sum(case[1] == "FAIL" for case in source["hidden"]) == 25
    assert SOURCE_SENTENCE in source["desc"]
    description = source["desc"].replace(SOURCE_SENTENCE, NEUTRAL_SENTENCE)
    assert re.search(r"\b(?:luax|els)\b", description, flags=re.IGNORECASE) is None

    visible_hash = value_hash(source["visible"])
    hidden_hash = value_hash(source["hidden"])
    task = {
        "id": source["id"],
        "fn": source["fn"],
        "in": source["in"],
        "out": source["out"],
        "desc": description,
        "difficulty": "hard",
        "family": "stateful-scripting",
        "tags": [
            "stateful",
            "transactions",
            "parsing",
            "fallible",
            "string",
            "hard",
        ],
        "visible": source["visible"],
        "hidden": source["hidden"],
        "provenance": {
            "source_repository": "_luax",
            "source_path": "experiment/tasks/kvstore.json",
            "source_sha256": file_hash(SOURCE),
            "source_visible_value_sha256": visible_hash,
            "source_hidden_value_sha256": hidden_hash,
            "description_edit": "neutral-error-signalling-wording-only",
            "case_transform": "none",
        },
    }

    TASK_OUT.parent.mkdir(parents=True, exist_ok=True)
    PYTHON_REF_OUT.parent.mkdir(parents=True, exist_ok=True)
    write_json(TASK_OUT, task)
    # Preserve the reference source string exactly as stored in the source JSON.
    PYTHON_REF_OUT.write_text(source["ref_python"], encoding="utf-8", newline="\n")

    generated = json.loads(TASK_OUT.read_text(encoding="utf-8"))
    assert generated["visible"] == source["visible"]
    assert generated["hidden"] == source["hidden"]
    assert value_hash(generated["visible"]) == visible_hash
    assert value_hash(generated["hidden"]) == hidden_hash
    assert PYTHON_REF_OUT.read_text(encoding="utf-8") == source["ref_python"]

    visible_values = {json.dumps(row, sort_keys=True, separators=(",", ":")) for row in source["visible"]}
    hidden_values = [json.dumps(row, sort_keys=True, separators=(",", ":")) for row in source["hidden"]]
    provenance = {
        "schema_version": 1,
        "frozen_date": "2026-07-11",
        "origin": "Luax blind-agent experiment kvstore hard-task probe",
        "source_repository": "_luax",
        "source_vcs_revision": None,
        "source_vcs_note": "the available _luax tree has no VCS metadata; hashes are authoritative",
        "source_task": {
            "path": "experiment/tasks/kvstore.json",
            "sha256": file_hash(SOURCE),
        },
        "source_fuzzer": {
            "path": "experiment/bin/fuzz_kvstore.py",
            "sha256": file_hash(SOURCE_FUZZER),
        },
        "source_retrospective": {
            "path": "RETROSPECTIVE.md",
            "sha256": file_hash(SOURCE_RETROSPECTIVE),
            "historical_claim": "reports differential agreement across 1700+ generated command sequences",
            "retained_machine_log": False,
        },
        "import_script": {
            "path": "experiment/kvstore_probe/import_corpus.py",
            "sha256": file_hash(Path(__file__).resolve()),
        },
        "description_edits": ["neutral-error-signalling-wording-only"],
        "case_transform": "none",
        "counts": {
            "visible": len(source["visible"]),
            "hidden": len(source["hidden"]),
            "hidden_fail": sum(case[1] == "FAIL" for case in source["hidden"]),
            "hidden_unique": len(set(hidden_values)),
            "hidden_rows_matching_visible": sum(row in visible_values for row in hidden_values),
        },
        "case_value_sha256": {
            "visible": visible_hash,
            "hidden": hidden_hash,
        },
        "source_reference_text_sha256": {
            "python": text_hash(source["ref_python"]),
            "els": text_hash(source["ref_els"]),
        },
        "generated": {
            "task_path": "experiment/kvstore_probe/corpus/kvstore.json",
            "task_sha256": file_hash(TASK_OUT),
            "python_reference_path": "experiment/kvstore_probe/refs/python/kvstore.py",
            "python_reference_sha256": file_hash(PYTHON_REF_OUT),
        },
    }
    write_json(PROVENANCE_OUT, provenance)
    print(
        "imported kvstore: "
        f"{len(source['visible'])} visible, {len(source['hidden'])} hidden, "
        f"{provenance['counts']['hidden_fail']} hidden FAIL"
    )


if __name__ == "__main__":
    main()
