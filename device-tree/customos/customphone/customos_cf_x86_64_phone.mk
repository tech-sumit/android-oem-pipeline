#
# CustomOS - Cuttlefish x86_64 phone OEM flavor.
# Inherits the upstream AOSP Cuttlefish phone product, then overrides
# branding properties and bakes in custom root CA certificates.
#
# Lunch:   customos_cf_x86_64_phone-userdebug
# Output:  out/target/product/vsoc_x86_64/
#

# Inherit AOSP Cuttlefish phone target (provides BoardConfig, partitions,
# vendor, kernel, etc. for the vsoc_x86_64 virtual device).
$(call inherit-product, device/google/cuttlefish/vsoc_x86_64/aosp_cf.mk)

LOCAL_PATH := $(call my-dir)

# ---- Product identity ------------------------------------------------------
# These drive the build-system PRODUCT_* variables and feed build.prop.

PRODUCT_NAME         := customos_cf_x86_64_phone
PRODUCT_DEVICE       := vsoc_x86_64
PRODUCT_BRAND        := CustomOS
PRODUCT_MODEL        := CustomPhone 1
PRODUCT_MANUFACTURER := CustomOS

# ---- Runtime ro.product.* property overrides -------------------------------
# Modern Android emits per-partition ro.product.<partition>.* from each
# partition's build.prop; we override every partition for consistent output
# from `getprop ro.product.*`.

PRODUCT_PROPERTY_OVERRIDES += \
    ro.product.brand=CustomOS \
    ro.product.system.brand=CustomOS \
    ro.product.system_ext.brand=CustomOS \
    ro.product.product.brand=CustomOS \
    ro.product.vendor.brand=CustomOS \
    ro.product.odm.brand=CustomOS \
    ro.product.model=CustomPhone\ 1 \
    ro.product.system.model=CustomPhone\ 1 \
    ro.product.system_ext.model=CustomPhone\ 1 \
    ro.product.product.model=CustomPhone\ 1 \
    ro.product.vendor.model=CustomPhone\ 1 \
    ro.product.odm.model=CustomPhone\ 1 \
    ro.product.manufacturer=CustomOS \
    ro.product.system.manufacturer=CustomOS \
    ro.product.system_ext.manufacturer=CustomOS \
    ro.product.product.manufacturer=CustomOS \
    ro.product.vendor.manufacturer=CustomOS \
    ro.product.odm.manufacturer=CustomOS \
    ro.oem.flavor=customos \
    ro.oem.build.tag=customos.20260427

# ---- Custom root CA certificates -------------------------------------------
# Bake every <hash>.0 file under security/cacerts/ into
# /system/etc/security/cacerts/. The pipeline's after-sync hook stages CAs
# here using the Android-style filename (subject_hash_old + .0), so this
# wildcard picks up anything add-ca.sh adds without editing this makefile.
#
# NOTE (Android 14+): TrustManagerImpl prefers the Conscrypt APEX trust store
# at /apex/com.android.conscrypt/cacerts/. Files dropped here remain a valid
# secondary source but apps that load Conscrypt directly may not pick them up.
# See docs/conscrypt-apex.md for the v2 plan to rebuild the APEX with our CAs.

CUSTOMOS_CA_FILES := $(wildcard $(LOCAL_PATH)/security/cacerts/*.0)
PRODUCT_COPY_FILES += $(foreach f,$(CUSTOMOS_CA_FILES),\
    $(f):system/etc/security/cacerts/$(notdir $(f)))

# ---- Build fingerprint -----------------------------------------------------
# BUILD_FINGERPRINT is auto-generated from the above when not explicitly set;
# leaving it implicit so AOSP fills in BUILD_ID / BUILD_NUMBER from the build.
# Uncomment and customize to lock the fingerprint string:
#
# BUILD_FINGERPRINT := CustomOS/customos_cf_x86_64_phone/customphone:16/CUSTOM.20260427.001/eng.customos:userdebug/release-keys

# ---- Bundled apps / framework overlays (optional, empty for v1) ------------
# PRODUCT_PACKAGES += MyOemLauncher MySettingsApp
# DEVICE_PACKAGE_OVERLAYS := $(LOCAL_PATH)/overlay
