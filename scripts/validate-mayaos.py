#!/usr/bin/env python3
"""Validate that MayaOS profile/device-tree files agree with each other.

This is intentionally narrow: it does not run the full Android build, it just
asserts the small set of cross-file invariants the pipeline depends on so that
typos do not silently change the spoof identity or drop a payload module.
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEVICE = ROOT / "device-tree" / "mayaos" / "galaxy-s26-ultra"


def _read(rel: Path) -> str:
    return rel.read_text()


def main() -> int:
    ET.parse(ROOT / "manifests" / "mayaos.xml")
    ET.parse(DEVICE / "sku" / "galaxy-s26-ultra-features.xml")

    yaml_text = _read(ROOT / "mayaos.yaml")
    products = _read(DEVICE / "AndroidProducts.mk")
    bp = _read(DEVICE / "Android.bp")
    x86_mk = _read(DEVICE / "mayaos_cf_s26ultra.mk")
    arm_mk = _read(DEVICE / "mayaos_cf_s26ultra_arm64.mk")

    must_contain = [
        ("intel profile", "id: galaxy-s26-ultra-intel-gpu", yaml_text),
        ("apple profile", "id: galaxy-s26-ultra-apple-silicon", yaml_text),
        (
            "x86 lunch yaml",
            "lunch_target: mayaos_cf_s26ultra-trunk_staging-userdebug",
            yaml_text,
        ),
        (
            "arm lunch yaml",
            "lunch_target: mayaos_cf_s26ultra_arm64-trunk_staging-userdebug",
            yaml_text,
        ),
        ("x86 lunch ap", "mayaos_cf_s26ultra-trunk_staging-userdebug", products),
        (
            "arm lunch ap",
            "mayaos_cf_s26ultra_arm64-trunk_staging-userdebug",
            products,
        ),
        ("x86 model", "PRODUCT_MODEL        := SM-S948B", x86_mk),
        ("arm model", "PRODUCT_MODEL        := SM-S948B", arm_mk),
        # Soong modules in Android.bp.
        (
            "bp features module",
            'name: "mayaos_galaxy-s26-ultra-features.xml"',
            bp,
        ),
        ("bp command-exec sh_binary", 'name: "mayaos-command-exec"', bp),
        ("bp command-exec init", 'name: "mayaos-command-exec.rc"', bp),
        ("bp vendor command-exec", "vendor: true", bp),
        # Product makefiles must opt into the Soong modules via PRODUCT_PACKAGES.
        ("x86 features pkg", "mayaos_galaxy-s26-ultra-features.xml", x86_mk),
        ("arm features pkg", "mayaos_galaxy-s26-ultra-features.xml", arm_mk),
        ("x86 command runner pkg", "mayaos-command-exec", x86_mk),
        ("arm command runner pkg", "mayaos-command-exec", arm_mk),
        ("x86 init pkg", "mayaos-command-exec.rc", x86_mk),
        ("arm init pkg", "mayaos-command-exec.rc", arm_mk),
    ]

    must_not_contain = [
        # No more PRODUCT_COPY_FILES paths for the Soong-owned payloads;
        # those should flow through PRODUCT_PACKAGES + Android.bp now.
        (
            "x86 no copy file (features)",
            "sku/galaxy-s26-ultra-features.xml:system",
            x86_mk,
        ),
        (
            "arm no copy file (features)",
            "sku/galaxy-s26-ultra-features.xml:system",
            arm_mk,
        ),
        (
            "x86 no copy file (command-exec)",
            "vendor/bin/mayaos-command-exec:vendor/bin",
            x86_mk,
        ),
        (
            "arm no copy file (command-exec)",
            "vendor/bin/mayaos-command-exec:vendor/bin",
            arm_mk,
        ),
        (
            "x86 no copy file (init.rc)",
            "vendor/etc/init/mayaos-command-exec.rc:vendor/etc/init",
            x86_mk,
        ),
        (
            "arm no copy file (init.rc)",
            "vendor/etc/init/mayaos-command-exec.rc:vendor/etc/init",
            arm_mk,
        ),
    ]

    failed = [name for name, needle, hay in must_contain if needle not in hay]
    failed += [name for name, needle, hay in must_not_contain if needle in hay]

    if failed:
        print("failed checks: " + ", ".join(failed), file=sys.stderr)
        return 1

    print("ok: MayaOS multi-target checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
