#
# MayaOS Galaxy S26 Ultra - Cuttlefish arm64 profile.
#
# arm64 sibling of mayaos_cf_s26ultra.mk. Inherits the same shared
# spoof block from vendor/mayaos/product.mk; only the inherit base,
# board, ABI list, and OEM tag suffix differ.
#
# Lunch:   mayaos_cf_s26ultra_arm64-trunk_staging-userdebug
# Output:  out/target/product/vsoc_arm64/
#

$(call inherit-product, device/google/cuttlefish/vsoc_arm64/phone/aosp_cf.mk)

PRODUCT_NAME         := mayaos_cf_s26ultra_arm64
PRODUCT_DEVICE       := vsoc_arm64

PRODUCT_PROPERTY_OVERRIDES += \
    ro.product.cpu.abilist=arm64-v8a \
    ro.product.cpu.abilist64=arm64-v8a \
    ro.product.cpu.abilist32=

PRODUCT_PROPERTY_OVERRIDES += \
    ro.oem.build.tag=mayaos.devicefarm.s26ultra.arm64

$(call inherit-product, vendor/mayaos/product.mk)
