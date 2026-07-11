#!/usr/bin/env python3
"""Deterministic preregistered posterior and paired sensitivity analysis."""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import random
import statistics
import sys
from typing import Any

BIN = Path(__file__).resolve().parent
if str(BIN) not in sys.path:
    sys.path.insert(0, str(BIN))

from common import ARMS, HarnessError, TASK_COUNT, TRIALS_PER_ARM, atomic_write_json


POSTERIOR_SEED = 20260711
BOOTSTRAP_SEED = 20260712
DEFAULT_DRAWS = 200_000
MARGIN = 0.10


def quantile(sorted_values: list[float], probability: float) -> float:
    if not sorted_values:
        raise HarnessError("cannot take a quantile of an empty sample")
    location = probability * (len(sorted_values) - 1)
    lower = math.floor(location)
    upper = math.ceil(location)
    if lower == upper:
        return sorted_values[lower]
    weight = location - lower
    return sorted_values[lower] * (1.0 - weight) + sorted_values[upper] * weight


def _load_rows(path: Path) -> list[dict[str, Any]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise HarnessError(f"cannot load rows {path}: {exc}") from exc
    if type(value) is dict:
        value = value.get("rows")
    if type(value) is not list:
        raise HarnessError("rows input must be a list or an object containing rows")
    return value


def _summarize_rows(rows: list[dict[str, Any]]) -> tuple[list[str], dict[tuple[str, str], dict[str, Any]]]:
    grouped: dict[tuple[str, str], dict[str, Any]] = {}
    tasks = sorted({str(row.get("task")) for row in rows})
    for task in tasks:
        task_rows = [row for row in rows if row.get("task") == task]
        families = {row.get("family") for row in task_rows}
        difficulties = {row.get("difficulty") for row in task_rows}
        if len(families) != 1 or len(difficulties) != 1:
            raise HarnessError(f"inconsistent strata for task {task}")
        for arm in ARMS:
            selected = [row for row in task_rows if row.get("arm") == arm]
            valid = [
                row
                for row in selected
                if row.get("valid") is True
                and type(row.get("hidden")) is dict
            ]
            solved = sum(row["hidden"].get("all") is True for row in valid)
            grouped[(task, arm)] = {
                "n": len(valid),
                "solved": solved,
                "assigned": len(selected),
                "family": next(iter(families)),
                "difficulty": next(iter(difficulties)),
            }
    return tasks, grouped


def analyze(rows: list[dict[str, Any]], *, draws: int = DEFAULT_DRAWS) -> dict[str, Any]:
    if draws < 10_000:
        raise HarnessError("posterior/bootstrap draws must be at least 10,000")
    tasks, grouped = _summarize_rows(rows)
    completeness: list[str] = []
    if len(tasks) != TASK_COUNT:
        completeness.append(f"expected {TASK_COUNT} tasks, found {len(tasks)}")
    for task in tasks:
        for arm in ARMS:
            cell = grouped[(task, arm)]
            if cell["assigned"] != TRIALS_PER_ARM:
                completeness.append(
                    f"{task}/{arm}: assigned {cell['assigned']}, expected {TRIALS_PER_ARM}"
                )
            if cell["n"] != TRIALS_PER_ARM:
                completeness.append(
                    f"{task}/{arm}: valid completed n={cell['n']}, expected {TRIALS_PER_ARM}"
                )

    paired_rows: list[dict[str, Any]] = []
    for task in tasks:
        machteld = grouped[(task, "machteld")]
        python = grouped[(task, "python")]
        m_rate = machteld["solved"] / machteld["n"] if machteld["n"] else None
        p_rate = python["solved"] / python["n"] if python["n"] else None
        difference = m_rate - p_rate if m_rate is not None and p_rate is not None else None
        paired_rows.append(
            {
                "task": task,
                "family": machteld["family"],
                "difficulty": machteld["difficulty"],
                "machteld_solved": machteld["solved"],
                "machteld_n": machteld["n"],
                "python_solved": python["solved"],
                "python_n": python["n"],
                "observed_difference": difference,
            }
        )
    result: dict[str, Any] = {
        "format": "machteld-serious-analysis-v1",
        "task_count": len(tasks),
        "trials_per_task_arm": TRIALS_PER_ARM,
        "margin": MARGIN,
        "complete": not completeness,
        "completeness_errors": completeness,
        "paired_tasks": paired_rows,
    }
    if completeness:
        result["classification"] = "unavailable_incomplete_valid_cells"
        return result

    # Independent Jeffreys posteriors, exactly as preregistered.  The pinned
    # Python runtime plus fixed seed make the standard-library generator
    # reproducible byte-for-byte for this experiment.
    posterior_rng = random.Random(POSTERIOR_SEED)
    deltas: list[float] = []
    for _ in range(draws):
        total = 0.0
        for task in tasks:
            m = grouped[(task, "machteld")]
            p = grouped[(task, "python")]
            m_draw = posterior_rng.betavariate(
                m["solved"] + 0.5, TRIALS_PER_ARM - m["solved"] + 0.5
            )
            p_draw = posterior_rng.betavariate(
                p["solved"] + 0.5, TRIALS_PER_ARM - p["solved"] + 0.5
            )
            total += m_draw - p_draw
        deltas.append(total / len(tasks))
    ordered = sorted(deltas)
    lower = quantile(ordered, 0.025)
    median = quantile(ordered, 0.5)
    upper = quantile(ordered, 0.975)
    probability_gt_zero = sum(value > 0 for value in deltas) / draws
    probability_gt_margin = sum(value > MARGIN for value in deltas) / draws
    probability_lt_negative_margin = sum(value < -MARGIN for value in deltas) / draws
    probability_equivalent = sum(abs(value) < MARGIN for value in deltas) / draws
    if probability_gt_margin >= 0.99:
        classification = "machteld_materially_easier"
    elif probability_lt_negative_margin >= 0.99:
        classification = "python_materially_easier"
    elif probability_equivalent >= 0.95 and lower >= -MARGIN and upper <= MARGIN:
        classification = "practically_equivalent"
    else:
        classification = "inconclusive"

    differences = [float(row["observed_difference"]) for row in paired_rows]
    family_values: dict[str, list[float]] = defaultdict(list)
    for row, difference in zip(paired_rows, differences):
        family_values[str(row["family"])].append(difference)
    bootstrap_rng = random.Random(BOOTSTRAP_SEED)
    bootstraps: list[float] = []
    for _ in range(draws):
        values: list[float] = []
        for family in sorted(family_values):
            source = family_values[family]
            values.extend(source[bootstrap_rng.randrange(len(source))] for _ in source)
        bootstraps.append(statistics.fmean(values))
    bootstraps.sort()

    result.update(
        {
            "classification": classification,
            "posterior": {
                "method": "independent Beta(s+0.5, 3-s+0.5) per task/arm",
                "seed": POSTERIOR_SEED,
                "draws": draws,
                "delta_definition": "mean_task(p_machteld - p_python)",
                "median": median,
                "credible_interval_95": [lower, upper],
                "p_delta_gt_zero": probability_gt_zero,
                "p_delta_gt_0_10": probability_gt_margin,
                "p_delta_lt_minus_0_10": probability_lt_negative_margin,
                "p_abs_delta_lt_0_10": probability_equivalent,
            },
            "paired_sensitivity": {
                "observed_mean": statistics.fmean(differences),
                "observed_median": statistics.median(differences),
                "positive_tasks": sum(value > 0 for value in differences),
                "negative_tasks": sum(value < 0 for value in differences),
                "tied_tasks": sum(value == 0 for value in differences),
                "bootstrap": {
                    "method": "paired task resampling within family; percentile interval",
                    "seed": BOOTSTRAP_SEED,
                    "draws": draws,
                    "interval_95": [
                        quantile(bootstraps, 0.025),
                        quantile(bootstraps, 0.975),
                    ],
                },
            },
        }
    )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--draws", type=int, default=DEFAULT_DRAWS)
    args = parser.parse_args()
    try:
        result = analyze(_load_rows(args.rows), draws=args.draws)
        if args.output:
            atomic_write_json(args.output, result)
        print(
            json.dumps(
                {
                    "classification": result["classification"],
                    "complete": result["complete"],
                    "posterior": result.get("posterior"),
                },
                ensure_ascii=True,
                indent=2,
            )
        )
        return 0 if result["complete"] else 2
    except (HarnessError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
