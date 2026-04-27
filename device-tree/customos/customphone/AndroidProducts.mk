#
# Lunch enumeration for the CustomOS Cuttlefish OEM product.
# AOSP build system globs device/*/*/AndroidProducts.mk to find lunch combos.
#

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/customos_cf_x86_64_phone.mk

COMMON_LUNCH_CHOICES := \
    customos_cf_x86_64_phone-userdebug \
    customos_cf_x86_64_phone-eng
