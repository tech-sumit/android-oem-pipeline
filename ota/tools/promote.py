#!/usr/bin/env python3
"""Promote a build between OTA channels.

The build entry stays in the source channel (channels are mostly
independent timelines), but is also copied to the destination channel
and bubbled to position [0] (i.e. it becomes the latest there).

Usage::

    python ota/tools/promote.py \
        --from canary \
        --to   stable \
        --build 16-r6-rc1
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "ota" / "site"
INDEX = SITE / "channels.json"


def load(name: str) -> dict:
    p = SITE / f"{name}.json"
    if not p.exists():
        raise FileNotFoundError(f"missing channel: {p}")
    return json.loads(p.read_text())


def save(name: str, doc: dict) -> None:
    p = SITE / f"{name}.json"
    p.write_text(json.dumps(doc, indent=2, sort_keys=True))


def main() -> int:
    ap = argparse.ArgumentParser(description="promote a build between OTA channels")
    ap.add_argument("--from", dest="src", required=True)
    ap.add_argument("--to",   dest="dst", required=True)
    ap.add_argument("--build", required=True)
    args = ap.parse_args()

    src = load(args.src)
    dst = load(args.dst)
    candidate = next((b for b in src["builds"] if b["id"] == args.build), None)
    if candidate is None:
        print(f"FAIL: build {args.build} not found in channel {args.src}", file=sys.stderr)
        return 1

    promoted = dict(candidate)
    promoted["promoted_from"] = args.src
    dst["builds"] = [promoted] + [b for b in dst["builds"] if b["id"] != args.build]
    if args.dst == "stable":
        dst["builds"] = dst["builds"][:10]
    save(args.dst, dst)

    if INDEX.exists():
        idx = json.loads(INDEX.read_text())
        idx.setdefault("channels", {})
        idx["channels"].setdefault(args.dst, {})
        idx["channels"][args.dst]["latest"] = args.build
        INDEX.write_text(json.dumps(idx, indent=2, sort_keys=True))

    print(f"ok: promoted {args.build}: {args.src} -> {args.dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
