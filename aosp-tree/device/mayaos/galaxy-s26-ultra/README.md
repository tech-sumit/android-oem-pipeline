# `device/mayaos/galaxy-s26-ultra/` — Galaxy S26 Ultra device tree

Holds the four lockstep MayaOS profile makefiles for the Samsung Galaxy
S26 Ultra spoof. Every shared bit (the actual `ro.product.*` block,
PRODUCT_PACKAGES, BUILD_FINGERPRINT, AAPT density, etc.) lives in
`vendor/mayaos/product.mk` — these per-profile .mk files are the thin
wrapper that picks the right upstream inherit base, sets the per-arch
ABI list, and inherits the shared block.

| Profile | Lunch | Inherit base | Output board |
|---|---|---|---|
| `mayaos_cf_s26ultra` | `mayaos_cf_s26ultra-trunk_staging-userdebug` | `device/google/cuttlefish/vsoc_x86_64/phone/aosp_cf.mk` | `vsoc_x86_64` |
| `mayaos_cf_s26ultra_arm64` | `mayaos_cf_s26ultra_arm64-trunk_staging-userdebug` | `device/google/cuttlefish/vsoc_arm64/phone/aosp_cf.mk` | `vsoc_arm64` |
| `mayaos_emu_s26ultra` | `mayaos_emu_s26ultra-trunk_staging-userdebug` | `device/generic/goldfish/64bitonly/product/sdk_phone64_arm64.mk` | `emu64a` |
| `mayaos_emu_s26ultra_x86_64` | `mayaos_emu_s26ultra_x86_64-trunk_staging-userdebug` | `device/generic/goldfish/64bitonly/product/sdk_phone64_x86_64.mk` | `emu64x` |

## Files

- `AndroidProducts.mk` — registers the four .mk files and their
  matching lunch combos in `COMMON_LUNCH_CHOICES`.
- `mayaos_cf_s26ultra.mk` — Cuttlefish x86_64.
- `mayaos_cf_s26ultra_arm64.mk` — Cuttlefish arm64.
- `mayaos_emu_s26ultra.mk` — Android Studio emulator arm64 (HVF on Mac).
- `mayaos_emu_s26ultra_x86_64.mk` — Android Studio emulator x86_64 (TCG fleet on RunPod).
- `sku/galaxy-s26-ultra-features.xml` — `PackageManager.hasSystemFeature()` declarations.
- `overlay/` — empty placeholder for framework resource overlays.

## Per-profile differences

The thin .mk files only set what differs between profiles:

```make
$(call inherit-product, <upstream-base>.mk)

PRODUCT_NAME         := mayaos_<variant>
PRODUCT_DEVICE       := <board>

# Per-arch ABI list (the only spoof field that varies):
PRODUCT_PROPERTY_OVERRIDES += \
    ro.product.cpu.abilist=<arch-list> \
    ...

# Per-profile OEM build tag suffix:
PRODUCT_PROPERTY_OVERRIDES += \
    ro.oem.build.tag=mayaos.devicefarm.s26ultra.<variant>

# Bring in the shared spoof block, BUILD_FINGERPRINT, PRODUCT_PACKAGES,
# AAPT density, surface_flinger config, etc.
$(call inherit-product, vendor/mayaos/product.mk)
```

Everything else is in `vendor/mayaos/product.mk`.
