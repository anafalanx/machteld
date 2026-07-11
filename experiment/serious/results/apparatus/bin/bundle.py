#!/usr/bin/env python3
"""Write or verify the closed result-bundle inventory."""

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


FORMAT = "machteld-serious-closed-bundle-v1"
MANIFEST_NAME = "bundle-manifest.json"


def inventory(root: Path) -> dict[str, dict[str, Any]]:
    return {
        path.relative_to(root).as_posix(): {"bytes": path.stat().st_size, "sha256": sha256(path)}
        for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix())
        if path.is_file() and path.resolve() != (root / MANIFEST_NAME).resolve()
    }


def write(root: Path, *, replace: bool = False) -> str:
    if not root.is_dir():
        raise HarnessError(f"results directory not found: {root}")
    manifest_path = root / MANIFEST_NAME
    if manifest_path.exists() and not replace:
        raise HarnessError("bundle manifest already exists; verify it or use --replace-manifest")
    files = inventory(root)
    if not files:
        raise HarnessError("refusing to seal an empty result bundle")
    document = {
        "format": FORMAT,
        "policy": "every regular file below results is listed except bundle-manifest.json itself",
        "files": files,
        "file_count": len(files),
        "total_bytes": sum(record["bytes"] for record in files.values()),
    }
    atomic_write_json(manifest_path, document)
    return sha256(manifest_path)


def verify(root: Path) -> str:
    manifest_path = root / MANIFEST_NAME
    try:
        document = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise HarnessError(f"cannot read bundle manifest: {exc}") from exc
    if document.get("format") != FORMAT or type(document.get("files")) is not dict:
        raise HarnessError("unexpected bundle-manifest format")
    expected = document["files"]
    actual_names = set(inventory(root))
    expected_names = set(expected)
    if actual_names != expected_names:
        missing = sorted(expected_names - actual_names)
        extra = sorted(actual_names - expected_names)
        raise HarnessError(f"bundle inventory mismatch; missing={missing[:5]} extra={extra[:5]}")
    for relative, record in expected.items():
        path = root / relative
        if path.stat().st_size != record.get("bytes"):
            raise HarnessError(f"bundle byte-count mismatch: {relative}")
        if sha256(path) != record.get("sha256"):
            raise HarnessError(f"bundle hash mismatch: {relative}")
    if document.get("file_count") != len(expected):
        raise HarnessError("bundle file_count mismatch")
    if document.get("total_bytes") != sum(record["bytes"] for record in expected.values()):
        raise HarnessError("bundle total_bytes mismatch")
    return sha256(manifest_path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("write", "verify"))
    parser.add_argument("--results", type=Path, default=RESULTS)
    parser.add_argument("--replace-manifest", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "write":
            digest = write(args.results, replace=args.replace_manifest)
            action = "sealed"
        else:
            if args.replace_manifest:
                raise HarnessError("--replace-manifest is valid only with write")
            digest = verify(args.results)
            action = "verified"
        count = len(inventory(args.results))
        print(f"PASS  {action} closed bundle ({count} files)")
        print(f"bundle-manifest sha256: {digest}")
        return 0
    except (HarnessError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
