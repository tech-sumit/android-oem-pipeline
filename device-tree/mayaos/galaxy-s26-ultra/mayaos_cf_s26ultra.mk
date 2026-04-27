#
# MayaOS Device Farm - Samsung Galaxy S26 Ultra spoof profile.
#
# Inherits the upstream AOSP Cuttlefish phone target (vsoc_x86_64) and
# overrides every consumer-visible identity property to match a real
# Samsung Galaxy S26 Ultra (SM-S948B). Used by the device farm to run apps
# under test against an emulator that looks, to the app, like an S26 Ultra.
#
# Lunch:   mayaos_cf_s26ultra-trunk_staging-userdebug
# Output:  out/target/product/vsoc_x86_64/
#
# IMPORTANT: this file is hand-written but its `ro.product.*` and
# BUILD_FINGERPRINT values MUST stay in sync with the matching profile in
# /mayaos.yaml (id: galaxy-s26-ultra). The CI `validate-config` job and
# the pipeline's before-build hook both enforce parity. If you change a
# branding string here, change it in mayaos.yaml too (or vice versa).

# Inherit AOSP Cuttlefish phone target (provides BoardConfig, partitions,
# vendor, kernel, gfxstream-capable GPU stack for vsoc_x86_64).
$(call inherit-product, device/google/cuttlefish/vsoc_x86_64/phone/aosp_cf.mk)

LOCAL_PATH := $(call my-dir)

# ---- Product identity (AOSP build system) ----------------------------------
# These drive AOSP's PRODUCT_* variables. The PRODUCT_NAME stays in our
# namespace so the lunch combo is unambiguously ours, but PRODUCT_BRAND /
# MODEL / MANUFACTURER spoof the Samsung values that flow into build.prop.

PRODUCT_NAME         := mayaos_cf_s26ultra
PRODUCT_DEVICE       := vsoc_x86_64
PRODUCT_BRAND        := samsung
PRODUCT_MODEL        := SM-S948B
PRODUCT_MANUFACTURER := samsung

# ---- ro.product.* per-partition overrides ----------------------------------
# Modern Android emits ro.product.<partition>.* from each partition's
# build.prop; we override every partition for consistent `getprop ro.product.*`
# output (apps and SDKs consult arbitrary partitions; if even one disagrees
# with the rest, fingerprint-checking analytics can flag the device).

PRODUCT_PROPERTY_OVERRIDES += \
    ro.product.brand=samsung \
    ro.product.system.brand=samsung \
    ro.product.system_ext.brand=samsung \
    ro.product.product.brand=samsung \
    ro.product.vendor.brand=samsung \
    ro.product.odm.brand=samsung \
    ro.product.manufacturer=samsung \
    ro.product.system.manufacturer=samsung \
    ro.product.system_ext.manufacturer=samsung \
    ro.product.product.manufacturer=samsung \
    ro.product.vendor.manufacturer=samsung \
    ro.product.odm.manufacturer=samsung \
    ro.product.model=SM-S948B \
    ro.product.system.model=SM-S948B \
    ro.product.system_ext.model=SM-S948B \
    ro.product.product.model=SM-S948B \
    ro.product.vendor.model=SM-S948B \
    ro.product.odm.model=SM-S948B \
    ro.product.name=s26uxxx \
    ro.product.system.name=s26uxxx \
    ro.product.system_ext.name=s26uxxx \
    ro.product.product.name=s26uxxx \
    ro.product.vendor.name=s26uxxx \
    ro.product.odm.name=s26uxxx \
    ro.product.device=s26u \
    ro.product.system.device=s26u \
    ro.product.system_ext.device=s26u \
    ro.product.product.device=s26u \
    ro.product.vendor.device=s26u \
    ro.product.odm.device=s26u

# Build identity. BUILD_FINGERPRINT is the single most-checked string by
# analytics/SafetyNet replacements; getting this right is the difference
# between "looks like an emulator" and "looks like the real device".
PRODUCT_PROPERTY_OVERRIDES += \
    ro.build.id=BP1A.250505.005 \
    ro.build.display.id=S948BXXU1AYA1 \
    ro.build.version.incremental=S948BXXU1AYA1 \
    ro.build.version.release=16 \
    ro.build.version.sdk=36 \
    ro.build.tags=release-keys \
    ro.build.type=user \
    ro.build.user=dpi \
    ro.build.host=21DKC1B11 \
    ro.build.flavor=s26uxxx-user \
    ro.build.fingerprint=samsung/s26uxxx/s26u:16/BP1A.250505.005/S948BXXU1AYA1:user/release-keys

# Some apps key off these specifically.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.oem.flavor=galaxy-s26-ultra \
    ro.oem.build.tag=mayaos.devicefarm.s26ultra \
    ro.product.first_api_level=36 \
    ro.product.cpu.abilist=x86_64,arm64-v8a \
    ro.product.cpu.abilist64=x86_64,arm64-v8a \
    ro.product.cpu.abilist32= \
    ro.hardware=qcom \
    ro.boot.hardware=qcom \
    ro.config.knox=v40 \
    ro.config.tima=1 \
    ro.security.keystore.keytype=Default,RSA,EC \
    ro.security.vaultkeeper.feature=NW_DAR_ENABLED,SDP_ENABLED,SDPV3_ENABLED

# ---- Display / density ------------------------------------------------------
# Real S26 Ultra: 1440 x 3120 @ 505dpi, 120Hz, punch-hole-center cutout.
# AAPT must be told the right density so resource selection picks xxxhdpi
# assets where apps ship them; otherwise OEM apps render at the wrong scale.

PRODUCT_AAPT_CONFIG := normal xxxhdpi
PRODUCT_AAPT_PREF_CONFIG := xxxhdpi
PRODUCT_AAPT_PREBUILT_DPI := xxxhdpi xxhdpi xhdpi hdpi

PRODUCT_PROPERTY_OVERRIDES += \
    ro.sf.lcd_density=505 \
    ro.surface_flinger.max_frame_buffer_acquired_buffers=3 \
    ro.surface_flinger.max_virtual_display_dimension=4096 \
    ro.config.refresh_rate=120 \
    ro.surface_flinger.max_refresh_rate=120 \
    ro.surface_flinger.set_idle_timer_ms=80 \
    ro.surface_flinger.set_touch_timer_ms=200 \
    ro.surface_flinger.set_display_power_timer_ms=2000

# ---- GPU / OpenGL / Vulkan --------------------------------------------------
# gfxstream is what Cuttlefish exposes on host-GPU instances; we tell apps the
# device supports OpenGL ES 3.2 (which the Adreno 750 in the real S26 Ultra
# does, and which gfxstream forwards transparently to the host driver).

PRODUCT_PROPERTY_OVERRIDES += \
    ro.opengles.version=196610 \
    ro.hardware.egl=emulation \
    ro.hardware.gralloc=ranchu \
    debug.hwui.use_buffer_age=true \
    debug.hwui.renderer=skiagl

# ---- Telephony --------------------------------------------------------------
# Real S26 Ultra: dual-SIM (1 physical + 1 eSIM). Spoof both slots active.

PRODUCT_PROPERTY_OVERRIDES += \
    persist.radio.multisim.config=dsds \
    ro.telephony.default_network=33,33 \
    persist.radio.allow_pre_4g_call=1 \
    ro.config.combined_signal=true

# ---- Hardware features XML --------------------------------------------------
# PackageManager.hasSystemFeature(...) reads from XML files in
# /system/etc/permissions/ and /vendor/etc/permissions/. We ship a single
# generated permissions file naming every feature the real S26 Ultra reports.

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/sku/galaxy-s26-ultra-features.xml:system/etc/permissions/mayaos_galaxy-s26-ultra-features.xml

# ---- MayaOS command execution service ---------------------------------------
# Keep the image free of OEM bloatware. The only MayaOS payload is a root-owned
# vendor service that executes operator-provided scripts from /data/vendor/mayaos.

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/vendor/bin/mayaos-command-exec:vendor/bin/mayaos-command-exec \
    $(LOCAL_PATH)/vendor/etc/init/mayaos-command-exec.rc:vendor/etc/init/mayaos-command-exec.rc

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

MAYAOS_CA_FILES := $(wildcard $(LOCAL_PATH)/security/cacerts/*.0)
PRODUCT_COPY_FILES += $(foreach f,$(MAYAOS_CA_FILES),\
    $(f):system/etc/security/cacerts/$(notdir $(f)))

# ---- Locked build fingerprint (override AOSP's auto-generated one) ----------
# AOSP normally synthesizes BUILD_FINGERPRINT from PRODUCT_BRAND/MODEL/etc at
# build time. We pin it here to byte-match the real S26 Ultra so analytics
# SDKs that hash this exact string see the expected hash.

BUILD_FINGERPRINT := samsung/s26uxxx/s26u:16/BP1A.250505.005/S948BXXU1AYA1:user/release-keys

# ---- Bundled apps / framework overlays --------------------------------------
# Intentionally empty: no Samsung/OEM bloatware is bundled into MayaOS.
# DEVICE_PACKAGE_OVERLAYS := $(LOCAL_PATH)/overlay
