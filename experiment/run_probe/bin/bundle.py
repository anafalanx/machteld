#!/usr/bin/env python3
"""Write or verify a closed SHA-256 manifest for a result bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys


EXP = Path(__file__).resolve().parents[1]
DEFAULT_ROOT = EXP / "results"
MANIFEST_NAME = "bundle-manifest.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inventory(root: Path) -> dict[str, dict[str, object]]:
    files: dict[str, dict[str, object]] = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path == root / MANIFEST_NAME:
            continue
        relative = path.relative_to(root).as_posix()
        files[relative] = {"sha256": sha256(path), "bytes": path.stat().st_size}
    return files


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("write", "verify"))
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--force", action="store_true", help="replace an existing manifest")
    args = parser.parse_args()
    root = args.root.resolve()
    if not root.is_dir():
        parser.error(f"bundle directory not found: {root}")
    manifest_path = root / MANIFEST_NAME

    if args.action == "write":
        if manifest_path.exists() and not args.force:
            parser.error(f"bundle manifest already exists; use --force to re-seal: {manifest_path}")
        files = inventory(root)
        document = {
            "format": "machteld-run-probe-result-bundle-v1",
            "algorithm": "sha256",
            "files": files,
        }
        manifest_path.write_text(
            json.dumps(document, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
        print(f"wrote {manifest_path} ({len(files)} files)")
        print(f"manifest SHA-256: {sha256(manifest_path)}")
        return 0

    if not manifest_path.is_file():
        print(f"bundle manifest missing: {manifest_path}", file=sys.stderr)
        return 1
    try:
        document = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"invalid bundle manifest: {exc}", file=sys.stderr)
        return 1
    if document.get("format") != "machteld-run-probe-result-bundle-v1":
        print("unexpected bundle format", file=sys.stderr)
        return 1
    if document.get("algorithm") != "sha256":
        print("unexpected bundle hash algorithm", file=sys.stderr)
        return 1
    expected = document.get("files")
    if not isinstance(expected, dict):
        print("invalid bundle file inventory", file=sys.stderr)
        return 1
    actual = inventory(root)
    if actual == expected:
        print(f"PASS  bundle integrity ({len(actual)} files)")
        return 0
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    changed = sorted(
        path for path in set(actual) & set(expected) if actual[path] != expected[path]
    )
    if missing:
        print("missing: " + ", ".join(missing), file=sys.stderr)
    if extra:
        print("extra: " + ", ".join(extra), file=sys.stderr)
    if changed:
        print("changed: " + ", ".join(changed), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
