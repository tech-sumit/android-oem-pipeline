#
# MayaOS Galaxy S26 Ultra - Cuttlefish x86_64 profile.
#
# Inherits the upstream AOSP Cuttlefish phone target (vsoc_x86_64) and
# the shared MayaOS spoof block. The shared block lives in
# vendor/mayaos/product.mk -- this file only carries what differs between
# the four Galaxy S26 Ultra profiles:
#   - upstream inherit base (cuttlefish vs sdk_phone, x86 vs arm)
#   - PRODUCT_NAME / PRODUCT_DEVICE
#   - per-arch ABI list (ro.product.cpu.abilist*)
#   - per-profile ro.oem.build.tag suffix
#
# Lunch:   mayaos_cf_s26ultra-trunk_staging-userdebug
# Output:  out/target/product/vsoc_x86_64/
#

# Inherit AOSP Cuttlefish phone target (provides BoardConfig, partitions,
# vendor, kernel, gfxstream-capable GPU stack for vsoc_x86_64).
$(call inherit-product, device/google/cuttlefish/vsoc_x86_64/phone/aosp_cf.mk)

PRODUCT_NAME         := mayaos_cf_s26ultra
PRODUCT_DEVICE       := vsoc_x86_64

# Per-arch ABI list (the only spoof field that varies between profiles).
# x86_64 with arm64 binary translation (via houdini if present).
PRODUCT_PROPERTY_OVERRIDES += \
    ro.product.cpu.abilist=x86_64,arm64-v8a \
    ro.product.cpu.abilist64=x86_64,arm64-v8a \
    ro.product.cpu.abilist32=

# Per-profile OEM build-tag suffix (some Samsung-aware apps key off this).
PRODUCT_PROPERTY_OVERRIDES += \
    ro.oem.build.tag=mayaos.devicefarm.s26ultra

# Bring in the shared spoof block, BUILD_FINGERPRINT, PRODUCT_PACKAGES,
# AAPT density, surface_flinger config, mayaos.prop, CA bake, etc.
$(call inherit-product, vendor/mayaos/product.mk)
