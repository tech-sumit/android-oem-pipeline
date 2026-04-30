#
# Lunch enumeration for the MayaOS Galaxy S26 Ultra spoof profile.
# AOSP build system globs device/*/*/AndroidProducts.mk to find lunch combos.
#

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/mayaos_cf_s26ultra.mk \
    $(LOCAL_DIR)/mayaos_cf_s26ultra_arm64.mk \
    $(LOCAL_DIR)/mayaos_emu_s26ultra.mk \
    $(LOCAL_DIR)/mayaos_emu_s26ultra_x86_64.mk

COMMON_LUNCH_CHOICES := \
    mayaos_cf_s26ultra-trunk_staging-userdebug \
    mayaos_cf_s26ultra-trunk_staging-eng \
    mayaos_cf_s26ultra_arm64-trunk_staging-userdebug \
    mayaos_cf_s26ultra_arm64-trunk_staging-eng \
    mayaos_emu_s26ultra-trunk_staging-userdebug \
    mayaos_emu_s26ultra-trunk_staging-eng \
    mayaos_emu_s26ultra_x86_64-trunk_staging-userdebug \
    mayaos_emu_s26ultra_x86_64-trunk_staging-eng
