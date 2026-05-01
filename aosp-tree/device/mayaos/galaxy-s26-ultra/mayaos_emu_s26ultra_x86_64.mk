#
# MayaOS Galaxy S26 Ultra - Android Studio Emulator (x86_64) profile.
#
# x86_64 sibling of mayaos_emu_s26ultra.mk -- the TCG-on-RunPod fleet
# image. Inherits AOSP's sdk_phone64_x86_64 (emu64x board, ranchu kernel,
# gfxstream GPU stack). Built on the A6000 pod and consumed by the STF
# emulator provider via qemu-system-x86_64.
#
# Lunch:   mayaos_emu_s26ultra_x86_64-trunk_staging-userdebug
# Output:  out/target/product/emu64x/
#
# x86_64 fleet runs with these abilist values so arm64-v8a-only APKs can
# load via houdini if the upstream build pulls it in. This matches what
# real Samsung S26 Ultra firmware would advertise on a hypothetical
# x86_64 SKU.

$(call inherit-product, device/generic/goldfish/64bitonly/product/sdk_phone64_x86_64.mk)

PRODUCT_NAME         := mayaos_emu_s26ultra_x86_64
PRODUCT_DEVICE       := emu64x

PRODUCT_PROPERTY_OVERRIDES += \
    ro.product.cpu.abilist=x86_64,arm64-v8a \
    ro.product.cpu.abilist64=x86_64,arm64-v8a \
    ro.product.cpu.abilist32=

PRODUCT_PROPERTY_OVERRIDES += \
    ro.oem.build.tag=mayaos.devicefarm.s26ultra.emu.x86_64

# Houdini opt-in for arm-on-x86 binary translation (some upstream
# emulator images ship the prebuilt Intel translator under this guard).
BUILD_ARM_FOR_X86_KEY1 := true

$(call inherit-product, vendor/mayaos/product.mk)

# Soong's inherit-product treats single-value vars (PRODUCT_BRAND / MODEL /
# DEVICE / NAME / MANUFACTURER) as FIRST-NON-EMPTY-WINS during the inherit
# walk. sdk_phone64_x86_64.mk's body sets PRODUCT_BRAND := Android and
# PRODUCT_MODEL := "Android SDK built for x86_64", and our inherit of
# vendor/mayaos/product.mk *cannot* override those (the inherit copies the
# child's single-value var only if the parent's slot is still empty).
#
# Setting these here in the leaf .mk body, AFTER all inherit-product calls,
# is the only spot where := unambiguously wins -- the same trick upstream
# uses (sdk_phone64_x86_64.mk pins PRODUCT_BRAND := Android in its own body
# after its own inherits). With these set, generate-common-build-props will
# emit ro.product.<partition>.brand=samsung / .model=SM-S948B for the vendor
# partition, so PRODUCT_PROPERTY_OVERRIDES (which also writes samsung /
# SM-S948B) becomes an identical-value duplicate -> post_process_props
# silently dedupes -> vendor/build.prop succeeds.
PRODUCT_BRAND        := samsung
PRODUCT_MODEL        := SM-S948B
PRODUCT_MANUFACTURER := samsung
