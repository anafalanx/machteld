#!/usr/bin/env python3
"""Write or verify the closed kvstore result-bundle inventory."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any

BIN = Path(__file__).resolve().parent
if str(BIN) not in sys.path:
    sys.path.insert(0, str(BIN))

from common import HarnessError, RESULTS, atomic_write_json, sha256


FORMAT = "machteld-kvstore-closed-bundle-v1"
NAME = "bundle-manifest.json"


def inventory(root: Path) -> dict[str, dict[str, Any]]:
    return {path.relative_to(root).as_posix(): {"bytes": path.stat().st_size, "sha256": sha256(path)}
            for path in sorted(root.rglob("*"), key=lambda p: p.relative_to(root).as_posix())
            if path.is_file() and path.resolve() != (root / NAME).resolve()}


def write(root: Path, replace: bool = False) -> str:
    if not root.is_dir(): raise HarnessError(f"results directory not found: {root}")
    target = root / NAME
    if target.exists() and not replace: raise HarnessError("bundle manifest exists; verify it or use --replace-manifest")
    files = inventory(root)
    if not files: raise HarnessError("refusing to seal an empty bundle")
    atomic_write_json(target, {"format": FORMAT,
                               "policy": "every regular file below results is listed except bundle-manifest.json itself",
                               "files": files, "file_count": len(files),
                               "total_bytes": sum(row["bytes"] for row in files.values())})
    return sha256(target)


def verify(root: Path) -> str:
    target = root / NAME
    try: document = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc: raise HarnessError(f"cannot read bundle manifest: {exc}") from exc
    if document.get("format") != FORMAT or type(document.get("files")) is not dict:
        raise HarnessError("unexpected bundle format")
    actual = inventory(root); expected = document["files"]
    if set(actual) != set(expected): raise HarnessError("bundle inventory mismatch")
    for name, record in expected.items():
        if actual[name] != record: raise HarnessError(f"bundle hash/size mismatch: {name}")
    if document.get("file_count") != len(expected) or document.get("total_bytes") != sum(row["bytes"] for row in expected.values()):
        raise HarnessError("bundle count mismatch")
    return sha256(target)


def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("command", choices=("write", "verify"))
    parser.add_argument("--results", type=Path, default=RESULTS); parser.add_argument("--replace-manifest", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "write": digest = write(args.results, args.replace_manifest); action = "sealed"
        else:
            if args.replace_manifest: raise HarnessError("--replace-manifest only applies to write")
            digest = verify(args.results); action = "verified"
        print(f"PASS  {action} closed bundle ({len(inventory(args.results))} files)")
        print(f"bundle-manifest sha256: {digest}")
        return 0
    except (HarnessError, OSError, UnicodeError, json.JSONDecodeError) as exc: parser.error(str(exc))
    return 2


if __name__ == "__main__": raise SystemExit(main())
