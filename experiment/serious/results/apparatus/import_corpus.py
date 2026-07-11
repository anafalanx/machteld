#!/usr/bin/env python3
"""Reproducibly import the frozen Tika serious corpus.

The source JSON embeds both language references.  This importer writes the
language-neutral task records and the Python references, but deliberately does
not write refs/machteld (that directory has a separate owner).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import Counter
from pathlib import Path


SERIOUS_ROOT = Path(__file__).resolve().parent
DEFAULT_SOURCE = Path(__file__).resolve().parents[3] / "_tika" / "experiment" / "tasks_serious"
CORPUS_DIR = SERIOUS_ROOT / "corpus"
PYTHON_REFS_DIR = SERIOUS_ROOT / "refs" / "python"

EXPECTED_TOTALS = {
    "tasks": 30,
    "visible": 90,
    "hidden": 464,
}
EXPECTED_CASE_NOVELTY = {
    "hidden_rows": 464,
    "hidden_rows_matching_visible": 17,
    "repeated_hidden_rows": 2,
    "novel_unique_hidden_rows": 445,
}
EXPECTED_DIFFICULTIES = {"mid": 4, "hard": 18, "very-hard": 8}
EXPECTED_FAMILIES = {
    "validator": 12,
    "number-theory": 7,
    "bit-encoding": 7,
    "interpreter": 4,
}

# The source report freezes only the four stratum totals.  This exhaustive map
# makes the corresponding per-task assignment explicit before any new trial.
FAMILY_TASKS = {
    "validator": {
        "bracket_balanced",
        "damm_check",
        "damm_valid",
        "date_valid",
        "iban_check",
        "isbn10_valid",
        "isbn13_valid",
        "luhn_valid",
        "mod97_checkdigits",
        "roman_value",
        "semver_cmp",
        "upca_check",
    },
    "number-theory": {
        "crt2",
        "jacobi",
        "miller_rabin",
        "modinv",
        "multiorder",
        "sum_of_two_squares",
        "totient",
    },
    "bit-encoding": {
        "extract_bits",
        "fnv1a32",
        "leb128_length",
        "popcount",
        "reverse_bits",
        "zigzag_decode",
        "zigzag_encode",
    },
    "interpreter": {
        "collatz_max",
        "gray_decode",
        "regmachine",
        "rpn_eval",
    },
}

FAMILY_BY_TASK = {
    task_id: family
    for family, task_ids in FAMILY_TASKS.items()
    for task_id in task_ids
}

# These are description-only edits.  They remove advice that existed solely
# because of Tika's surface while retaining every input convention, operation,
# edge condition, and expected result.  Each source fragment must occur once;
# source drift therefore fails loudly instead of silently changing the import.
DESCRIPTION_EDITS: dict[str, list[tuple[str, str, str]]] = {
    "collatz_max": [
        (
            "fixed-width-overflow-advice",
            " The test set picks n so that no intermediate value overflows int64 (all inputs n <= 1,000,000 plus small/edge values), but a correct solution must use the exact Collatz recurrence.",
            " The tested positive inputs are at most 1,000,000; use the exact Collatz recurrence.",
        ),
    ],
    "crt2": [
        (
            "tika-remainder",
            "(Tika mod truncates toward zero, so add the modulus if negative)",
            "(if the remainder is negative, add the modulus)",
        ),
        (
            "fixed-width-lcm-advice",
            "(5) lcm = (m1/g)*m2 to avoid overflow; answer normalized into [0, lcm).",
            "(5) lcm = (m1/g)*m2; answer normalized into [0, lcm).",
        ),
        (
            "fixed-width-overflow-advice",
            " OVERFLOW: keep m1, m2 <= 1e9 (coprime worst case lcm ~ 1e18 < 2^63) and r1+m1*t stays below lcm so it fits int64.",
            " Test inputs have m1 and m2 <= 1e9; their lcm and the expected answer fit signed 64-bit integers.",
        ),
    ],
    "damm_check": [
        (
            "fixed-width-leading-power-advice",
            ", so you must first find the highest power of 10 <= n and peel the leading digit each step (n/p then n mod p, p/=10);",
            "; process the actual decimal digits from left to right;",
        ),
        (
            "tika-no-arrays",
            "(3) the table lookup needs no arrays - encode each row as a packed integer and select;",
            "(3) use the supplied quasigroup table exactly;",
        ),
        (
            "fixed-width-overflow-advice",
            "; (5) finding the top power of 10 must NOT overflow (use n/p>=10 to step p, never p*10 compared past 10^18).",
            ".",
        ),
    ],
    "damm_valid": [
        (
            "fixed-width-leading-power-advice",
            "; must work for the full int64 range up to 9223372036854775807 (19 digits) WITHOUT overflow (naively building 10^(numdigits) overflows for 19-digit inputs, so cap the power-of-ten at 10^18).",
            "; values through 9223372036854775807 contain up to 19 digits and must all be processed.",
        ),
        (
            "tika-no-arrays",
            " The table must be encoded arithmetically (no arrays): each row as a constant and the entry T[r][d] extracted as row_const // 10^(9-d) % 10 (leading-zero suppression of a row constant is fine because the division by 10^(9-d) recovers the right digit).",
            "",
        ),
    ],
    "date_valid": [
        (
            "fixed-width-overflow-comment",
            " No overflow concerns (d fits int64).",
            "",
        ),
    ],
    "extract_bits": [
        (
            "fixed-width-mask-advice",
            "building the low-width mask must NOT overflow int64 (the naive (1<<width)-1 overflows for width==63 and width==64) so use an overflow-safe mask (all-ones logically right-shifted by 64-width); ",
            "",
        ),
    ],
    "fnv1a32": [
        (
            "tika-shift-name",
            "with LOGICAL rshift by 8*i",
            "with a logical right shift by 8*i",
        ),
        (
            "fixed-width-overflow-comment",
            " The product h*16777619 stays well within int64 (< 2^57) so no overflow occurs.",
            "",
        ),
    ],
    "iban_check": [
        (
            "fixed-width-direct-arithmetic-advice",
            " Because n*100 overflows int64 for large n, you MUST reduce modulo 97 without forming n*100 directly: compute r = n mod 97 (digit-by-digit or via powers of ten mod 97, never multiplying n by 100), then C = 98 - ((r*100) mod 97).",
            " Equivalently, with r = n mod 97, C = 98 - ((r*100) mod 97).",
        ),
        (
            "fixed-width-overflow-trap",
            "the multiply-by-100 overflow trap means a naive 98 - (n*100) % 97 crashes (int_overflow) for big n while still being arithmetically the intended definition; ",
            "",
        ),
        (
            "language-comparison",
            "mod here is on non-negative operands so C and Python semantics coincide.",
            "All remainder operations here use non-negative operands.",
        ),
    ],
    "jacobi": [
        (
            "tika-remainder",
            " (normalizing a negative residue into [0,n) — note Tika mod truncates toward zero)",
            " (normalizing a negative residue into [0,n) by adding n when needed)",
        ),
        (
            "fixed-width-overflow-comment",
            " Inputs keep n below ~30000 (and a anywhere in int64 but the tested a are modest); products stay well within int64.",
            " Tested n values are below ~30000; tested a values are modest signed integers.",
        ),
    ],
    "luhn_valid": [
        (
            "fixed-width-overflow-comment",
            "(5) works up to 9223372036854775807 (int64 max) with no overflow since you only sum small per-digit contributions.",
            "(5) the signed-64-bit maximum 9223372036854775807 is included.",
        ),
    ],
    "miller_rabin": [
        (
            "fixed-width-bound-rationale",
            "inputs are capped at n <= 3,037,000,499 (the modmul-overflow bound, where n^2 fits in int64), so",
            "inputs are capped at n <= 3,037,000,499, so",
        ),
        (
            "fixed-width-overflow-advice",
            " OVERFLOW: every product (a*b mod n, both operands < n <= 3037000499) stays below 2^63; do all multiplies as plain int64 with reduction.",
            "",
        ),
    ],
    "mod97_checkdigits": [
        (
            "fixed-width-difficulty-heading",
            "The hard part / what bites: ",
            "Equivalent form and edge cases: ",
        ),
        (
            "fixed-width-direct-arithmetic-advice",
            "(1) OVERFLOW - n can be up to ~10^18, so computing n*100 directly OVERFLOWS int64 (and in Tika raises int_overflow, aborting); you MUST reduce first: r = ((n mod 97) * 100) mod 97 (which stays tiny) before the final adjustment - a naive 'n*100 mod 97' fails on large inputs;",
            "(1) EQUIVALENT REDUCTION - r = ((n mod 97) * 100) mod 97 may be used before the final adjustment;",
        ),
        (
            "language-remainder-comparison",
            "(2) SIGN of mod - Tika's mod truncates toward zero, so 1 - r (with r in 0..96, giving values down to -95) yields a NEGATIVE remainder; you must add 97 when negative to land in [0,96] (Python's % already floors, so the two refs must be made to agree here);",
            "(2) SIGN of remainder - 1 - r can be negative (down to -95), so normalize it into [0,96];",
        ),
    ],
    "modinv": [
        (
            "tika-remainder",
            " Note Tika's mod truncates toward zero, so after `a mod m` a negative a needs `+m`.",
            " If the remainder is negative, add m.",
        ),
        (
            "fixed-width-overflow-comment",
            " Inputs kept with |a| and m below ~2e9 so extended-Euclid coefficients stay within int64.",
            " Tested |a| and m values are below ~2e9.",
        ),
    ],
    "multiorder": [
        (
            "tika-remainder",
            "(Tika mod truncates toward zero, so add n if negative)",
            "(if the remainder is negative, add n)",
        ),
        (
            "fixed-width-overflow-advice",
            " OVERFLOW: keep n <= 3037000499 so cur*a (both < n) stays < 2^63; tested moduli are <= ~1e6 with small orders for speed.",
            " The input domain is limited to n <= 3037000499; tested moduli are <= ~1e6 with small orders for speed.",
        ),
    ],
    "popcount": [
        (
            "tika-shift-name",
            "using LOGICAL right shift (rshift, zero-fill)",
            "using a logical right shift (zero-fill)",
        ),
    ],
    "regmachine": [
        (
            "language-division-comparison",
            "(5) the C-truncating semantics of opcodes 5 and 11 differ from Python's floor for negatives -- get the sign right.",
            "(5) opcodes 5 and 11 use the specified truncation and signed-remainder semantics for negative values.",
        ),
    ],
    "reverse_bits": [
        (
            "tika-shift-name",
            "with LOGICAL rshift then mask with 1",
            "with a logical right shift then mask with 1",
        ),
    ],
    "sum_of_two_squares": [
        (
            "fixed-width-overflow-comment",
            " Inputs kept <= ~1e9 so p*p does not overflow and trial division to sqrt is fast.",
            " Tested inputs are <= ~1e9, so trial division to sqrt is fast.",
        ),
    ],
    "totient": [
        (
            "fixed-width-overflow-advice",
            "implemented overflow-safely as result -= result/p",
            "computed exactly as result -= result/p",
        ),
        (
            "fixed-width-overflow-comment",
            " Inputs kept <= ~1e9 so trial division to sqrt(n) (~31623 steps) is fast and p*p does not overflow.",
            " Tested inputs are <= ~1e9, so trial division to sqrt(n) (~31623 steps) is fast.",
        ),
    ],
    "zigzag_decode": [
        (
            "tika-unary-minus",
            " Build the all-ones mask as 0 - (u and 1) (tika has no unary minus).",
            "",
        ),
    ],
    "zigzag_encode": [
        (
            "tika-combine-advice",
            " Use ARITHMETIC shift for the sign mask and LOGICAL-or-via-xor combine.",
            "",
        ),
        (
            "fixed-width-bound-rationale",
            " Critical: the input range is restricted to -2^62 <= n <= 2^62-1 so the result always fits in a non-negative int64 in [0, 2^63-1] (a larger |n| would make n<<1 wrap the sign bit).",
            " Critical: the input range is restricted to -2^62 <= n <= 2^62-1, and the result is in [0, 2^63-1].",
        ),
    ],
}

BANNED_DESCRIPTION_MARKERS = (
    "tika",
    "python",
    "int_overflow",
    "no arrays",
    "rshift",
    "logical-or-via-xor",
    "to avoid overflow",
    "must not overflow",
    "overflows int64",
    "no overflow",
    "overflow-safe",
    "modmul-overflow",
    "p*p does not overflow",
)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def neutralize_description(task_id: str, source: str) -> tuple[str, list[str]]:
    result = source
    applied: list[str] = []
    for edit_id, old, new in DESCRIPTION_EDITS.get(task_id, []):
        count = result.count(old)
        if count != 1:
            raise ValueError(
                f"{task_id}: neutralization fragment {edit_id!r} occurs {count} times, expected 1"
            )
        result = result.replace(old, new)
        applied.append(edit_id)

    lowered = result.casefold()
    leftovers = [marker for marker in BANNED_DESCRIPTION_MARKERS if marker in lowered]
    if leftovers:
        raise ValueError(f"{task_id}: implementation-specific wording remains: {leftovers}")
    return result, applied


def load_sources(source_dir: Path) -> list[tuple[Path, bytes, dict[str, object]]]:
    paths = sorted(source_dir.glob("*.json"))
    if len(paths) != EXPECTED_TOTALS["tasks"]:
        raise ValueError(f"expected 30 source tasks, found {len(paths)} in {source_dir}")

    loaded = []
    for path in paths:
        raw = path.read_bytes()
        try:
            task = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError(f"cannot load {path}: {exc}") from exc
        loaded.append((path, raw, task))
    return loaded


def build_outputs(source_dir: Path) -> tuple[dict[Path, bytes], dict[str, object]]:
    source_report = source_dir.parent / "results" / "REPORT_serious.md"
    if not source_report.is_file():
        raise ValueError(f"missing source report: {source_report}")

    outputs: dict[Path, bytes] = {}
    manifest_rows: list[dict[str, object]] = []
    difficulty_counts: Counter[str] = Counter()
    family_counts: Counter[str] = Counter()
    total_visible = 0
    total_hidden = 0
    hidden_visible_overlap = 0
    repeated_hidden = 0
    novel_unique_hidden = 0
    seen_ids: set[str] = set()

    required_source_keys = {
        "id", "word", "in", "out", "desc", "difficulty", "tags",
        "visible", "hidden", "ref_python", "ref_tika",
    }

    for source_path, source_raw, source in load_sources(source_dir):
        missing = required_source_keys - set(source)
        if missing:
            raise ValueError(f"{source_path.name}: missing keys {sorted(missing)}")

        task_id = source["id"]
        if not isinstance(task_id, str) or task_id != source_path.stem:
            raise ValueError(f"{source_path.name}: id/path mismatch")
        if task_id in seen_ids:
            raise ValueError(f"duplicate task id: {task_id}")
        seen_ids.add(task_id)
        if task_id not in FAMILY_BY_TASK:
            raise ValueError(f"{task_id}: no frozen family assignment")
        if source["word"] != task_id:
            raise ValueError(f"{task_id}: word differs from id")
        if not isinstance(source["in"], int) or not isinstance(source["out"], int):
            raise ValueError(f"{task_id}: in/out must be integers")
        if source["out"] != 1:
            raise ValueError(f"{task_id}: serious corpus expects one output")
        if not re.search(rf"(?m)^def\s+{re.escape(task_id)}\s*\(", source["ref_python"]):
            raise ValueError(f"{task_id}: embedded Python reference lacks def {task_id}")

        description, edits = neutralize_description(task_id, source["desc"])
        source_hash = sha256_bytes(source_raw)
        embedded_ref = source["ref_python"].encode("utf-8")
        ref_bytes = embedded_ref if embedded_ref.endswith(b"\n") else embedded_ref + b"\n"

        family = FAMILY_BY_TASK[task_id]
        provenance = {
            "source_repository": "_tika",
            "source_path": f"experiment/tasks_serious/{source_path.name}",
            "source_sha256": source_hash,
            "source_ref_python_sha256": sha256_bytes(embedded_ref),
            "import_script": "experiment/serious/import_corpus.py",
            "transformation": "word renamed to fn; description-only language neutralization; cases unchanged",
            "description_edits": edits,
        }
        neutral = {
            "id": task_id,
            "fn": source["word"],
            "in": source["in"],
            "out": source["out"],
            "desc": description,
            "difficulty": source["difficulty"],
            "family": family,
            "tags": source["tags"],
            "visible": source["visible"],
            "hidden": source["hidden"],
            "provenance": provenance,
        }
        if neutral["visible"] != source["visible"] or neutral["hidden"] != source["hidden"]:
            raise AssertionError(f"{task_id}: case mutation during import")

        task_bytes = json_bytes(neutral)
        task_target = CORPUS_DIR / f"{task_id}.json"
        ref_target = PYTHON_REFS_DIR / f"{task_id}.py"
        outputs[task_target] = task_bytes
        outputs[ref_target] = ref_bytes

        visible_count = len(source["visible"])
        hidden_count = len(source["hidden"])
        visible_keys = {
            json.dumps(case, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            for case in source["visible"]
        }
        hidden_keys = [
            json.dumps(case, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            for case in source["hidden"]
        ]
        hidden_key_set = set(hidden_keys)
        task_overlap = sum(key in visible_keys for key in hidden_keys)
        task_repeats = len(hidden_keys) - len(hidden_key_set)
        task_novel_unique = len(hidden_key_set - visible_keys)
        total_visible += visible_count
        total_hidden += hidden_count
        hidden_visible_overlap += task_overlap
        repeated_hidden += task_repeats
        novel_unique_hidden += task_novel_unique
        difficulty_counts[source["difficulty"]] += 1
        family_counts[family] += 1
        manifest_rows.append({
            "id": task_id,
            "family": family,
            "difficulty": source["difficulty"],
            "visible": visible_count,
            "hidden": hidden_count,
            "hidden_rows_matching_visible": task_overlap,
            "repeated_hidden_rows": task_repeats,
            "novel_unique_hidden_rows": task_novel_unique,
            "source_path": provenance["source_path"],
            "source_sha256": source_hash,
            "source_ref_python_sha256": provenance["source_ref_python_sha256"],
            "generated_task_path": f"experiment/serious/corpus/{task_id}.json",
            "generated_task_sha256": sha256_bytes(task_bytes),
            "generated_python_ref_path": f"experiment/serious/refs/python/{task_id}.py",
            "generated_python_ref_sha256": sha256_bytes(ref_bytes),
            "description_edits": edits,
        })

    if seen_ids != set(FAMILY_BY_TASK):
        missing = sorted(set(FAMILY_BY_TASK) - seen_ids)
        extra = sorted(seen_ids - set(FAMILY_BY_TASK))
        raise ValueError(f"frozen family map mismatch; missing={missing}, extra={extra}")

    actual_totals = {
        "tasks": len(seen_ids),
        "visible": total_visible,
        "hidden": total_hidden,
    }
    if actual_totals != EXPECTED_TOTALS:
        raise ValueError(f"case totals differ: {actual_totals} != {EXPECTED_TOTALS}")
    actual_case_novelty = {
        "hidden_rows": total_hidden,
        "hidden_rows_matching_visible": hidden_visible_overlap,
        "repeated_hidden_rows": repeated_hidden,
        "novel_unique_hidden_rows": novel_unique_hidden,
    }
    if actual_case_novelty != EXPECTED_CASE_NOVELTY:
        raise ValueError(
            f"case novelty differs: {actual_case_novelty} != {EXPECTED_CASE_NOVELTY}"
        )
    if dict(difficulty_counts) != EXPECTED_DIFFICULTIES:
        raise ValueError(
            f"difficulty counts differ: {dict(difficulty_counts)} != {EXPECTED_DIFFICULTIES}"
        )
    if dict(family_counts) != EXPECTED_FAMILIES:
        raise ValueError(f"family counts differ: {dict(family_counts)} != {EXPECTED_FAMILIES}")

    importer_hash = sha256_bytes(Path(__file__).read_bytes())
    source_report_hash = sha256_bytes(source_report.read_bytes())
    manifest = {
        "schema_version": 1,
        "frozen_date": "2026-07-11",
        "origin": "Tika serious corpus reported 2026-06-20",
        "source_repository": "_tika",
        "source_vcs_revision": None,
        "source_vcs_note": "the available _tika source tree has no VCS metadata; file hashes are authoritative",
        "source_root": "experiment/tasks_serious",
        "source_report": "experiment/results/REPORT_serious.md",
        "source_report_sha256": source_report_hash,
        "import_script": "experiment/serious/import_corpus.py",
        "import_script_sha256": importer_hash,
        "schema_fields": [
            "id", "fn", "in", "out", "desc", "difficulty", "family",
            "tags", "visible", "hidden", "provenance",
        ],
        "totals": actual_totals,
        "case_novelty": actual_case_novelty,
        "difficulty_counts": dict(sorted(difficulty_counts.items())),
        "family_counts": dict(sorted(family_counts.items())),
        "tasks": manifest_rows,
    }
    outputs[CORPUS_DIR / "PROVENANCE.json"] = json_bytes(manifest)
    outputs[CORPUS_DIR / "PROVENANCE.md"] = render_provenance_md(manifest).encode("utf-8")
    return outputs, manifest


def render_provenance_md(manifest: dict[str, object]) -> str:
    lines = [
        "# Serious corpus provenance",
        "",
        "This corpus is a reproducible, language-neutral projection of all 30",
        "validated tasks in `_tika/experiment/tasks_serious`. The source report is",
        "`_tika/experiment/results/REPORT_serious.md` (2026-06-20).",
        "",
        "The importer renames source `word` to neutral `fn`, adds the frozen family",
        "stratum, extracts the embedded Python reference, and removes only wording",
        "that prescribed a source-language or fixed-width implementation technique",
        "irrelevant to both bignum arms. Inputs, outputs,",
        "task behavior, visible cases, and hidden cases are unchanged.",
        "The available `_tika` tree has no VCS metadata, so the recorded relative",
        "paths plus SHA-256 hashes are the authoritative source identity.",
        "",
        "## Frozen totals",
        "",
        "- 30 tasks; 90 visible cases; 464 hidden cases.",
        "- Of 464 inherited hidden rows, 17 repeat a visible row and 2 repeat another hidden row within the same task, leaving 445 novel unique hidden rows.",
        "- Difficulty: 4 mid, 18 hard, 8 very-hard.",
        "- Family: 12 validator/checksum, 7 number-theory/crypto, 7 bit/encoding/hashing, 4 interpreter/state-machine.",
        "",
        "The source report states the stratum totals but not its per-task labels. The",
        "exhaustive mapping in `import_corpus.py` is therefore the prospective frozen",
        "operational mapping for this experiment. It was fixed before subject trials.",
        "",
        "## Reproduction",
        "",
        "From `C:\\dev\\_machteld`:",
        "",
        "```powershell",
        "C:\\dev\\z.exe python -I -S -B experiment/serious/import_corpus.py",
        "C:\\dev\\z.exe python -I -S -B experiment/serious/import_corpus.py --check",
        "```",
        "",
        f"Importer SHA-256: `{manifest['import_script_sha256']}`  ",
        f"Source report SHA-256: `{manifest['source_report_sha256']}`",
        "",
        "## Per-task hashes",
        "",
        "| Task | Family | Difficulty | Visible | Hidden | Novel hidden | Source SHA-256 | Neutral task SHA-256 | Python ref SHA-256 |",
        "|---|---|---:|---:|---:|---:|---|---|---|",
    ]
    for row in manifest["tasks"]:
        lines.append(
            f"| `{row['id']}` | {row['family']} | {row['difficulty']} | "
            f"{row['visible']} | {row['hidden']} | {row['novel_unique_hidden_rows']} | `{row['source_sha256']}` | "
            f"`{row['generated_task_sha256']}` | `{row['generated_python_ref_sha256']}` |"
        )
    lines.extend([
        "",
        "Machine-readable paths, hashes, edit identifiers, and counts are in",
        "`PROVENANCE.json`.",
    ])
    return "\n".join(lines) + "\n"


def compare_or_write(outputs: dict[Path, bytes], check_only: bool) -> None:
    expected_task_names = {
        path.name for path in outputs
        if path.parent == CORPUS_DIR and path.suffix == ".json" and path.name != "PROVENANCE.json"
    }
    expected_ref_names = {
        path.name for path in outputs if path.parent == PYTHON_REFS_DIR and path.suffix == ".py"
    }
    existing_task_names = {path.name for path in CORPUS_DIR.glob("*.json") if path.name != "PROVENANCE.json"}
    existing_ref_names = {path.name for path in PYTHON_REFS_DIR.glob("*.py")}
    unexpected = sorted((existing_task_names - expected_task_names) | (existing_ref_names - expected_ref_names))
    if unexpected:
        raise ValueError(f"unexpected generated corpus/reference files: {unexpected}")

    mismatches: list[str] = []
    for path, wanted in outputs.items():
        if check_only:
            if not path.is_file():
                mismatches.append(f"missing {path}")
            elif path.read_bytes() != wanted:
                mismatches.append(f"content differs: {path}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(wanted)
    if mismatches:
        raise ValueError("generated corpus is not reproducible:\n  " + "\n  ".join(mismatches))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=DEFAULT_SOURCE,
        help="source tasks_serious directory (default: sibling _tika repository)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify generated files byte-for-byte without writing",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        outputs, manifest = build_outputs(args.source_dir.resolve())
        compare_or_write(outputs, args.check)
    except (OSError, ValueError, AssertionError) as exc:
        print(f"import_corpus: ERROR: {exc}", file=sys.stderr)
        return 1

    mode = "verified" if args.check else "wrote"
    totals = manifest["totals"]
    print(
        f"import_corpus: {mode} {totals['tasks']} tasks, "
        f"{totals['visible']} visible, {totals['hidden']} hidden"
    )
    print(f"  case novelty: {manifest['case_novelty']}")
    print(f"  difficulty: {manifest['difficulty_counts']}")
    print(f"  family: {manifest['family_counts']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
