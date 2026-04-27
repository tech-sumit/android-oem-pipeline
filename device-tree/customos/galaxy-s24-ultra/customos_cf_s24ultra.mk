#
# CustomOS Device Farm - Samsung Galaxy S24 Ultra spoof profile.
#
# Inherits the upstream AOSP Cuttlefish phone target (vsoc_x86_64) and
# overrides every consumer-visible identity property to match a real
# Samsung Galaxy S24 Ultra (SM-S928B). Used by the device farm to run apps
# under test against an emulator that looks, to the app, like an S24 Ultra.
#
# Lunch:   customos_cf_s24ultra-userdebug
# Output:  out/target/product/vsoc_x86_64/
#
# IMPORTANT: this file is hand-written but its `ro.product.*` and
# BUILD_FINGERPRINT values MUST stay in sync with the matching profile in
# /customos.yaml (id: galaxy-s24-ultra). The CI `validate-config` job and
# the pipeline's before-build hook both enforce parity. If you change a
# branding string here, change it in customos.yaml too (or vice versa).

# Inherit AOSP Cuttlefish phone target (provides BoardConfig, partitions,
# vendor, kernel, gfxstream-capable GPU stack for vsoc_x86_64).
$(call inherit-product, device/google/cuttlefish/vsoc_x86_64/aosp_cf.mk)

LOCAL_PATH := $(call my-dir)

# ---- Product identity (AOSP build system) ----------------------------------
# These drive AOSP's PRODUCT_* variables. The PRODUCT_NAME stays in our
# namespace so the lunch combo is unambiguously ours, but PRODUCT_BRAND /
# MODEL / MANUFACTURER spoof the Samsung values that flow into build.prop.

PRODUCT_NAME         := customos_cf_s24ultra
PRODUCT_DEVICE       := vsoc_x86_64
PRODUCT_BRAND        := samsung
PRODUCT_MODEL        := SM-S928B
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
    ro.product.model=SM-S928B \
    ro.product.system.model=SM-S928B \
    ro.product.system_ext.model=SM-S928B \
    ro.product.product.model=SM-S928B \
    ro.product.vendor.model=SM-S928B \
    ro.product.odm.model=SM-S928B \
    ro.product.name=e3qxxx \
    ro.product.system.name=e3qxxx \
    ro.product.system_ext.name=e3qxxx \
    ro.product.product.name=e3qxxx \
    ro.product.vendor.name=e3qxxx \
    ro.product.odm.name=e3qxxx \
    ro.product.device=e3q \
    ro.product.system.device=e3q \
    ro.product.system_ext.device=e3q \
    ro.product.product.device=e3q \
    ro.product.vendor.device=e3q \
    ro.product.odm.device=e3q

# Build identity. BUILD_FINGERPRINT is the single most-checked string by
# analytics/SafetyNet replacements; getting this right is the difference
# between "looks like an emulator" and "looks like the real device".
PRODUCT_PROPERTY_OVERRIDES += \
    ro.build.id=AP3A.240905.015.A2 \
    ro.build.display.id=S928BXXU3AXJ4 \
    ro.build.version.incremental=S928BXXU3AXJ4 \
    ro.build.version.release=14 \
    ro.build.version.sdk=34 \
    ro.build.tags=release-keys \
    ro.build.type=user \
    ro.build.user=dpi \
    ro.build.host=21DKC1B11 \
    ro.build.flavor=e3qxxx-user \
    ro.build.fingerprint=samsung/e3qxxx/e3q:14/UP1A.231005.007/S928BXXU3AXJ4:user/release-keys

# Some apps key off these specifically.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.oem.flavor=galaxy-s24-ultra \
    ro.oem.build.tag=customos.devicefarm.s24ultra \
    ro.product.first_api_level=34 \
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
# Real S24 Ultra: 1440 x 3120 @ 505dpi, 120Hz, punch-hole-center cutout.
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
# device supports OpenGL ES 3.2 (which the Adreno 750 in the real S24 Ultra
# does, and which gfxstream forwards transparently to the host driver).

PRODUCT_PROPERTY_OVERRIDES += \
    ro.opengles.version=196610 \
    ro.hardware.egl=emulation \
    ro.hardware.gralloc=ranchu \
    debug.hwui.use_buffer_age=true \
    debug.hwui.renderer=skiagl

# ---- Telephony --------------------------------------------------------------
# Real S24 Ultra: dual-SIM (1 physical + 1 eSIM). Spoof both slots active.

PRODUCT_PROPERTY_OVERRIDES += \
    persist.radio.multisim.config=dsds \
    ro.telephony.default_network=33,33 \
    persist.radio.allow_pre_4g_call=1 \
    ro.config.combined_signal=true

# ---- Hardware features XML --------------------------------------------------
# PackageManager.hasSystemFeature(...) reads from XML files in
# /system/etc/permissions/ and /vendor/etc/permissions/. We ship a single
# generated permissions file naming every feature the real S24 Ultra reports.

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/sku/galaxy-s24-ultra-features.xml:system/etc/permissions/customos_galaxy-s24-ultra-features.xml

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

# ---- Locked build fingerprint (override AOSP's auto-generated one) ----------
# AOSP normally synthesizes BUILD_FINGERPRINT from PRODUCT_BRAND/MODEL/etc at
# build time. We pin it here to byte-match the real S24 Ultra so analytics
# SDKs that hash this exact string see the expected hash.

BUILD_FINGERPRINT := samsung/e3qxxx/e3q:14/UP1A.231005.007/S928BXXU3AXJ4:user/release-keys

# ---- Bundled apps / framework overlays (optional, empty for v1) ------------
# PRODUCT_PACKAGES += SamsungLikeLauncher SamsungLikeSettings
# DEVICE_PACKAGE_OVERLAYS := $(LOCAL_PATH)/overlay
