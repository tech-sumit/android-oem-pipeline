#
# Lunch enumeration for the CustomOS Galaxy S24 Ultra spoof profile.
# AOSP build system globs device/*/*/AndroidProducts.mk to find lunch combos.
#

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/customos_cf_s24ultra.mk

COMMON_LUNCH_CHOICES := \
    customos_cf_s24ultra-userdebug \
    customos_cf_s24ultra-eng
