#
# MayaOS Galaxy S26 Ultra - Android Studio Emulator (arm64) profile.
#
# Inherits AOSP's sdk_phone64_arm64 product (so the build emits AVD-shaped
# artifacts: kernel-ranchu, system-qemu.img, vendor-qemu.img, etc.). The
# shared MayaOS spoof comes from vendor/mayaos/product.mk.
#
# Lunch:   mayaos_emu_s26ultra-trunk_staging-userdebug
# Output:  out/target/product/emu64a/
#
# Boot path on Mac (Apple Silicon, HVF-accelerated, see plan §18.5 Option B):
#   make runpod-emulator-fetch PROFILE=galaxy-s26-ultra-emulator
#   make emulator-up           PROFILE=galaxy-s26-ultra-emulator
#

# Path note: in android-16.0.0_r* the sdk_phone* product makefiles live
# under device/generic/goldfish/, NOT under build/make/target/product/
# where they used to. The latter only has aosp_arm64.mk and friends.
$(call inherit-product, device/generic/goldfish/64bitonly/product/sdk_phone64_arm64.mk)

PRODUCT_NAME         := mayaos_emu_s26ultra
PRODUCT_DEVICE       := emu64a

PRODUCT_PROPERTY_OVERRIDES += \
    ro.product.cpu.abilist=arm64-v8a \
    ro.product.cpu.abilist64=arm64-v8a \
    ro.product.cpu.abilist32=

PRODUCT_PROPERTY_OVERRIDES += \
    ro.oem.build.tag=mayaos.devicefarm.s26ultra.emu

$(call inherit-product, vendor/mayaos/product.mk)

# See sibling x86_64 profile for the full rationale: inherit-product treats
# PRODUCT_BRAND / MODEL / MANUFACTURER as FIRST-NON-EMPTY single-value vars,
# so the upstream sdk_phone64_arm64.mk body's PRODUCT_BRAND := Android wins
# over vendor/mayaos/product.mk's PRODUCT_BRAND := samsung. Pinning the
# Samsung values here in the leaf .mk body (after all inherits) is the only
# guaranteed-last write and matches what upstream itself does to set
# PRODUCT_BRAND.
PRODUCT_BRAND        := samsung
PRODUCT_MODEL        := SM-S948B
PRODUCT_MANUFACTURER := samsung
