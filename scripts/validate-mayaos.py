#!/usr/bin/env python3
"""Validate that MayaOS aosp-tree files agree with each other and with mayaos.yaml.

This is intentionally narrow: it does not run the full Android build, it just
asserts the small set of cross-file invariants the pipeline depends on so that
typos do not silently change the spoof identity or drop a payload module.

Rev 5 (Waydroid-style 3-layer split):
    aosp-tree/device/mayaos/galaxy-s26-ultra/  -- per-device .mk + features.xml
    aosp-tree/vendor/mayaos/                   -- shared product.mk + Android.bp
    aosp-tree/hardware/mayaos/                 -- HALs (sensors, ...)
    aosp-tree/packages/apps/                   -- in-tree apps (MayaOSUpdater)
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
AOSP_TREE = ROOT / "aosp-tree"
DEVICE = AOSP_TREE / "device" / "mayaos" / "galaxy-s26-ultra"
VENDOR = AOSP_TREE / "vendor" / "mayaos"


def _read(rel: Path) -> str:
    return rel.read_text()


def main() -> int:
    ET.parse(ROOT / "manifests" / "mayaos.xml")
    ET.parse(DEVICE / "sku" / "galaxy-s26-ultra-features.xml")

    yaml_text = _read(ROOT / "mayaos.yaml")
    # MDF root CA must be staged into the vendor partition.
    cacerts_dir = VENDOR / "rootdir" / "system" / "etc" / "security" / "cacerts"
    cacert_files = sorted(p.name for p in cacerts_dir.glob("*.0"))
    products = _read(DEVICE / "AndroidProducts.mk")
    device_bp = _read(DEVICE / "Android.bp")
    vendor_bp = _read(VENDOR / "Android.bp")
    shared_mk = _read(VENDOR / "product.mk")
    x86_mk = _read(DEVICE / "mayaos_cf_s26ultra.mk")
    arm_mk = _read(DEVICE / "mayaos_cf_s26ultra_arm64.mk")
    emu_mk = _read(DEVICE / "mayaos_emu_s26ultra.mk")
    emu_x86_mk = _read(DEVICE / "mayaos_emu_s26ultra_x86_64.mk")
    board_extra = _read(VENDOR / "BoardConfigExtra.mk")
    vendorsetup = _read(VENDOR / "vendorsetup.sh")
    mayaos_prop = _read(VENDOR / "mayaos.prop")

    must_contain = [
        # mayaos.yaml profile entries.
        ("intel profile", "id: galaxy-s26-ultra-intel-gpu", yaml_text),
        ("apple profile", "id: galaxy-s26-ultra-apple-silicon", yaml_text),
        ("emu arm profile", "id: galaxy-s26-ultra-emulator", yaml_text),
        ("emu x86 profile", "id: galaxy-s26-ultra-emulator-x86", yaml_text),
        ("aosp-tree path in yaml", "aosp-tree/device/mayaos/galaxy-s26-ultra", yaml_text),

        # mayaos.yaml lunch targets.
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
        (
            "emu arm lunch yaml",
            "lunch_target: mayaos_emu_s26ultra-trunk_staging-userdebug",
            yaml_text,
        ),
        (
            "emu x86 lunch yaml",
            "lunch_target: mayaos_emu_s26ultra_x86_64-trunk_staging-userdebug",
            yaml_text,
        ),

        # AndroidProducts.mk lunch enumeration.
        ("x86 lunch ap", "mayaos_cf_s26ultra-trunk_staging-userdebug", products),
        ("arm lunch ap", "mayaos_cf_s26ultra_arm64-trunk_staging-userdebug", products),
        ("emu arm lunch ap", "mayaos_emu_s26ultra-trunk_staging-userdebug", products),
        ("emu x86 lunch ap", "mayaos_emu_s26ultra_x86_64-trunk_staging-userdebug", products),

        # Per-profile thin .mk files inherit shared product.mk.
        (
            "x86 inherits shared",
            "$(call inherit-product, vendor/mayaos/product.mk)",
            x86_mk,
        ),
        (
            "arm inherits shared",
            "$(call inherit-product, vendor/mayaos/product.mk)",
            arm_mk,
        ),
        (
            "emu arm inherits shared",
            "$(call inherit-product, vendor/mayaos/product.mk)",
            emu_mk,
        ),
        (
            "emu x86 inherits shared",
            "$(call inherit-product, vendor/mayaos/product.mk)",
            emu_x86_mk,
        ),

        # Each per-profile .mk inherits its upstream base.
        (
            "x86 inherits cuttlefish",
            "device/google/cuttlefish/vsoc_x86_64/phone/aosp_cf.mk",
            x86_mk,
        ),
        (
            "arm inherits cuttlefish",
            "device/google/cuttlefish/vsoc_arm64/phone/aosp_cf.mk",
            arm_mk,
        ),
        (
            "emu arm inherits sdk_phone arm",
            "device/generic/goldfish/64bitonly/product/sdk_phone64_arm64.mk",
            emu_mk,
        ),
        (
            "emu x86 inherits sdk_phone x86",
            "device/generic/goldfish/64bitonly/product/sdk_phone64_x86_64.mk",
            emu_x86_mk,
        ),

        # Per-profile PRODUCT_NAME (must NOT collide).
        ("x86 product name", "PRODUCT_NAME         := mayaos_cf_s26ultra", x86_mk),
        ("arm product name", "PRODUCT_NAME         := mayaos_cf_s26ultra_arm64", arm_mk),
        ("emu arm product name", "PRODUCT_NAME         := mayaos_emu_s26ultra", emu_mk),
        ("emu x86 product name", "PRODUCT_NAME         := mayaos_emu_s26ultra_x86_64", emu_x86_mk),

        # Shared spoof block lives in vendor/mayaos/product.mk now.
        ("shared model", "PRODUCT_MODEL        := SM-S948B", shared_mk),
        ("shared brand", "PRODUCT_BRAND        := samsung", shared_mk),
        ("shared manufacturer", "PRODUCT_MANUFACTURER := samsung", shared_mk),
        ("shared fingerprint", "samsung/s26uxxx/s26u:16/", shared_mk),
        ("shared marketing name", "ro.product.marketing_name=Galaxy", shared_mk),
        ("shared OS name", "ro.product.os_name=MayaOS", shared_mk),
        ("shared mayaos.prop bake", "vendor/mayaos/mayaos.prop:vendor/etc/mayaos.prop", shared_mk),

        # Per-profile ABI list (the only spoof field that varies).
        (
            "x86 abilist (x86_64,arm64)",
            "ro.product.cpu.abilist=x86_64,arm64-v8a",
            x86_mk,
        ),
        (
            "arm abilist (arm64-only)",
            "ro.product.cpu.abilist=arm64-v8a",
            arm_mk,
        ),
        (
            "emu arm abilist (arm64-only)",
            "ro.product.cpu.abilist=arm64-v8a",
            emu_mk,
        ),
        (
            "emu x86 abilist (x86_64,arm64)",
            "ro.product.cpu.abilist=x86_64,arm64-v8a",
            emu_x86_mk,
        ),

        # Soong modules: per-device features.xml in device/, shared command-exec
        # in vendor/.
        (
            "device bp features module",
            'name: "mayaos_galaxy-s26-ultra-features.xml"',
            device_bp,
        ),
        ("device bp vendor partition", "vendor: true", device_bp),
        ("vendor bp command-exec sh_binary", 'name: "mayaos-command-exec"', vendor_bp),
        ("vendor bp command-exec init", 'name: "mayaos-command-exec.rc"', vendor_bp),
        ("vendor bp vendor partition", "vendor: true", vendor_bp),
        (
            "vendor bp src points at vendor/bin",
            'src: "bin/mayaos-command-exec"',
            vendor_bp,
        ),

        # Shared product.mk opts in to the Soong modules via PRODUCT_PACKAGES.
        ("shared features pkg", "mayaos_galaxy-s26-ultra-features.xml", shared_mk),
        ("shared command runner pkg", "mayaos-command-exec", shared_mk),
        ("shared init pkg", "mayaos-command-exec.rc", shared_mk),

        # BoardConfigExtra has the dup-sysprop allow flag.
        ("board extra dup sysprop", "BUILD_BROKEN_DUP_SYSPROP := true", board_extra),

        # vendorsetup.sh registers all four lunch combos.
        ("vendorsetup x86 cf", "mayaos_cf_s26ultra-trunk_staging-userdebug", vendorsetup),
        ("vendorsetup arm cf", "mayaos_cf_s26ultra_arm64-trunk_staging-userdebug", vendorsetup),
        ("vendorsetup arm emu", "mayaos_emu_s26ultra-trunk_staging-userdebug", vendorsetup),
        ("vendorsetup x86 emu", "mayaos_emu_s26ultra_x86_64-trunk_staging-userdebug", vendorsetup),

        # mayaos.prop has the §6.5.6 boot tunings.
        ("mayaos.prop animations", "ro.windowanimationscale=0", mayaos_prop),
        ("mayaos.prop dexopt", "pm.dexopt.boot-after-ota=quicken", mayaos_prop),
        ("mayaos.prop heap cap", "dalvik.vm.heapsize=128m", mayaos_prop),
        # mayaos.yaml lists the MDF root CA in `cas:`.
        ("yaml lists MDF CA", "ca/mdf-root-ca.pem", yaml_text),
        # MayaOSUpdater system app is in PRODUCT_PACKAGES (Phase 6).
        ("product.mk has MayaOSUpdater", "MayaOSUpdater", shared_mk),
        ("product.mk has updater privapp perms", "privapp-permissions-mayaos-updater.xml", shared_mk),
    ]

    # MayaOSUpdater package layer must exist (Phase 6).
    updater_root = AOSP_TREE / "packages" / "apps" / "MayaOSUpdater"
    for f in ("Android.bp", "AndroidManifest.xml",
              "src/dev/mayaos/updater/UpdateCheckService.java",
              "src/dev/mayaos/updater/UpdateEngineBridge.java",
              "src/dev/mayaos/updater/MainActivity.java",
              "src/dev/mayaos/updater/BootReceiver.java",
              "privapp-permissions-mayaos-updater.xml"):
        if not (updater_root / f).exists():
            print(f"failed: missing MayaOSUpdater file: {(updater_root / f).relative_to(ROOT)}",
                  file=sys.stderr)
            return 1

    # MDF root CA must be present as a hashed .0 file in the vendor partition.
    if not cacert_files:
        print(
            f"failed: no .0 root CAs found in {cacerts_dir.relative_to(ROOT)}",
            file=sys.stderr,
        )
        return 1
    if len(cacert_files) < 2:
        print(
            f"failed: expected >=2 root CAs (demo + MDF) in "
            f"{cacerts_dir.relative_to(ROOT)}; found {cacert_files}",
            file=sys.stderr,
        )
        return 1

    must_not_contain = [
        # Per-profile .mk files must NOT redefine the shared spoof block any
        # more (would break inheritance ordering / cause dup-sysprop noise).
        ("x86 no PRODUCT_BRAND", "PRODUCT_BRAND        := samsung", x86_mk),
        ("arm no PRODUCT_BRAND", "PRODUCT_BRAND        := samsung", arm_mk),
        ("emu arm no PRODUCT_BRAND", "PRODUCT_BRAND        := samsung", emu_mk),
        ("emu x86 no PRODUCT_BRAND", "PRODUCT_BRAND        := samsung", emu_x86_mk),
        ("x86 no BUILD_FINGERPRINT", "BUILD_FINGERPRINT := samsung", x86_mk),
        ("arm no BUILD_FINGERPRINT", "BUILD_FINGERPRINT := samsung", arm_mk),
        ("emu arm no BUILD_FINGERPRINT", "BUILD_FINGERPRINT := samsung", emu_mk),
        ("emu x86 no BUILD_FINGERPRINT", "BUILD_FINGERPRINT := samsung", emu_x86_mk),
        # No more PRODUCT_COPY_FILES paths for the Soong-owned payloads.
        ("shared no copy file (features)", "sku/galaxy-s26-ultra-features.xml:system", shared_mk),
        ("shared no copy file (command-exec)", "vendor/bin/mayaos-command-exec:vendor/bin", shared_mk),
        ("shared no copy file (init.rc)", "vendor/etc/init/mayaos-command-exec.rc:vendor/etc/init", shared_mk),
    ]

    failed = [name for name, needle, hay in must_contain if needle not in hay]
    failed += [name for name, needle, hay in must_not_contain if needle in hay]

    if failed:
        print("failed checks: " + ", ".join(failed), file=sys.stderr)
        return 1

    print(f"ok: MayaOS aosp-tree checks passed ({len(must_contain) + len(must_not_contain)} assertions)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
