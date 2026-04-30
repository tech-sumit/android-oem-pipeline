#!/usr/bin/env python3
"""Append a fresh MayaOS build to an OTA channel.

Reads the post-build manifest written by ``after-build.sh``, computes
sha256 hashes of the artifacts, and produces / updates the JSON files
under ``ota/site/`` so Cloudflare Pages can serve them.

Usage::

    python ota/tools/append.py \
        --channel canary \
        --build-id 16-r6-rc1 \
        --profile  galaxy-s26-ultra-emulator-x86 \
        --artifact-dir out/target/product/galaxy-s26-ultra/dist/

The R2 upload is performed by ``after-build.sh``; this script only
reads the resulting public URLs from ``manifest.json`` written next to
the artifact dir.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "ota" / "site"
INDEX = SITE / "channels.json"
KNOWN_CHANNELS = ["stable", "canary", "dev"]


def sha256(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            buf = f.read(chunk)
            if not buf:
                break
            h.update(buf)
    return h.hexdigest()


def load_channel(name: str) -> dict:
    p = SITE / f"{name}.json"
    if p.exists():
        return json.loads(p.read_text())
    return {"v": 1, "channel": name, "builds": []}


def write_channel(name: str, doc: dict) -> None:
    SITE.mkdir(parents=True, exist_ok=True)
    p = SITE / f"{name}.json"
    p.write_text(json.dumps(doc, indent=2, sort_keys=True))


def update_index(channel: str, latest_id: str) -> None:
    SITE.mkdir(parents=True, exist_ok=True)
    if INDEX.exists():
        idx = json.loads(INDEX.read_text())
    else:
        idx = {"v": 1, "channels": {}}
    idx["generatedAt"] = dt.datetime.utcnow().isoformat() + "Z"
    idx.setdefault("channels", {})
    for c in KNOWN_CHANNELS:
        idx["channels"].setdefault(c, {
            "url": f"https://ota.mayaos.dev/{c}.json",
            "latest": None,
        })
    idx["channels"][channel]["latest"] = latest_id
    INDEX.write_text(json.dumps(idx, indent=2, sort_keys=True))


def main() -> int:
    ap = argparse.ArgumentParser(description="append a build to an OTA channel")
    ap.add_argument("--channel",  required=True, choices=KNOWN_CHANNELS + ["custom"])
    ap.add_argument("--build-id", required=True, help="e.g. 16-r6-rc1")
    ap.add_argument("--profile",  required=True, help="mayaos.yaml profile id")
    ap.add_argument("--artifact-dir", required=True, type=Path,
                    help="dir produced by after-build.sh containing manifest.json")
    ap.add_argument("--notes",    default="", help="release notes")
    args = ap.parse_args()

    manifest_path = args.artifact_dir / "manifest.json"
    if not manifest_path.exists():
        print(f"FAIL: missing manifest at {manifest_path}", file=sys.stderr)
        return 1

    manifest = json.loads(manifest_path.read_text())
    fingerprint = manifest.get("build_fingerprint")
    public = manifest.get("r2_urls", {})

    artifacts = {}
    for kind in ("system_img", "vendor_img", "boot_img"):
        local = args.artifact_dir / manifest["files"].get(kind, "")
        if not local.exists():
            print(f"FAIL: artifact missing locally: {local}", file=sys.stderr)
            return 1
        artifacts[kind] = {
            "url":    public.get(kind),
            "sha256": sha256(local),
            "size":   local.stat().st_size,
        }

    entry = {
        "id":          args.build_id,
        "ts":          int(dt.datetime.utcnow().timestamp()),
        "profile":     args.profile,
        "fingerprint": fingerprint,
        "notes":       args.notes,
        **artifacts,
    }

    doc = load_channel(args.channel)
    doc["builds"] = [entry] + [b for b in doc.get("builds", []) if b["id"] != args.build_id]
    if args.channel == "stable":
        doc["builds"] = doc["builds"][:10]
    elif args.channel == "canary":
        doc["builds"] = doc["builds"][:25]
    write_channel(args.channel, doc)
    update_index(args.channel, args.build_id)

    print(f"ok: appended {args.build_id} to channel '{args.channel}'")
    print(f"     {INDEX.relative_to(ROOT)}")
    print(f"     {(SITE / (args.channel + '.json')).relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
