#
# MayaOS Device Farm - Samsung Galaxy S26 Ultra spoof profile (Android Emulator).
#
# Mirrors mayaos_cf_s26ultra_arm64.mk's branding spoof but inherits from the
# AOSP SDK Phone arm64 target instead of Cuttlefish. This produces the
# emulator-flavored AVD bundle (kernel-ranchu, system-qemu.img,
# vendor-qemu.img, ramdisk-qemu.img, advancedFeatures.ini, etc.) that the
# Android Studio Emulator on Apple Silicon Mac (HVF-accelerated) consumes.
#
# Lunch:   mayaos_emu_s26ultra-trunk_staging-userdebug
# Output:  out/target/product/emu64a/
#
# WHY a separate file (not just reuse mayaos_cf_s26ultra_arm64.mk):
#   - cuttlefish target inherits device/google/cuttlefish/vsoc_arm64/phone/
#     aosp_cf.mk, which produces super.img + boot.img (Cuttlefish runtime).
#   - emulator target inherits build/target/product/sdk_phone64_arm64.mk,
#     which produces kernel-ranchu + system-qemu.img + ramdisk-qemu.img
#     (Android Studio Emulator runtime).
#   The branding spoof block is identical across both -- if you change a
#   ro.product.* / build_id / fingerprint here, change it in the cuttlefish
#   variants too. The CI `validate-config` job and the pipeline's before-build
#   hook enforce parity against /mayaos.yaml.
#

# Inherit AOSP SDK phone arm64 (provides emu64a board, ranchu kernel, gfxstream
# GPU, sdk_phone64_arm64 product config, etc.).
$(call inherit-product, $(SRC_TARGET_DIR)/product/sdk_phone64_arm64.mk)

# ---- Product identity (AOSP build system) ----------------------------------
# Same convention as the cuttlefish variants: PRODUCT_NAME stays in the mayaos
# namespace so the lunch combo is unambiguously ours; PRODUCT_DEVICE stays
# emu64a so the build emits the standard emulator-target (ranchu) artifacts;
# PRODUCT_BRAND/MODEL/MANUFACTURER spoof the Samsung Galaxy S26 Ultra values.

PRODUCT_NAME         := mayaos_emu_s26ultra
PRODUCT_DEVICE       := emu64a
PRODUCT_BRAND        := samsung
PRODUCT_MODEL        := SM-S948B
PRODUCT_MANUFACTURER := samsung

# ---- ro.product.* per-partition overrides ----------------------------------
# Override every partition's brand/manufacturer/model/name/device so apps that
# probe arbitrary partitions see consistent S26 Ultra identity. Same set as
# the cuttlefish variants -- KEEP IN SYNC.

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

# Settings's "Device name" reads ro.product.marketing_name first if set; without
# this it falls back to the bare ro.product.model ("SM-S948B"), which apps know
# but humans don't. Real Samsung firmware ships this for the consumer-friendly
# string ("Galaxy S26 Ultra"). Same logic for the OS branding block below.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.product.marketing_name=Galaxy\ S26\ Ultra \
    ro.product.vendor.marketing_name=Galaxy\ S26\ Ultra \
    ro.product.system.marketing_name=Galaxy\ S26\ Ultra

# Build identity. BUILD_FINGERPRINT is the single most-checked string by
# analytics/SafetyNet replacements; pinned here to byte-match the real S26
# Ultra firmware.
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

# OS branding -- this is what Settings > "About phone" > "Android version" /
# "Build number" surfaces alongside the Samsung device strings. Without these
# overrides the BP4A.* / Baklava codename leaks through and gives away that
# this is a stock AOSP build, not MayaOS.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.build.version.codename=REL \
    ro.build.version.all_codenames=REL \
    ro.build.version.preview_sdk=0 \
    ro.product.os_name=MayaOS \
    ro.product.os_version=16 \
    ro.mayaos.brand=MayaOS \
    ro.mayaos.version=16 \
    ro.mayaos.codename=Galaxy\ S26\ Ultra

# Per-OEM keys some Samsung-aware apps probe.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.oem.flavor=galaxy-s26-ultra \
    ro.oem.build.tag=mayaos.devicefarm.s26ultra.emu \
    ro.product.first_api_level=36 \
    ro.product.cpu.abilist=arm64-v8a \
    ro.product.cpu.abilist64=arm64-v8a \
    ro.product.cpu.abilist32= \
    ro.hardware=qcom \
    ro.boot.hardware=qcom \
    ro.config.knox=v40 \
    ro.config.tima=1 \
    ro.security.keystore.keytype=Default,RSA,EC \
    ro.security.vaultkeeper.feature=NW_DAR_ENABLED,SDP_ENABLED,SDPV3_ENABLED

# ---- Display / density ------------------------------------------------------
# Real S26 Ultra: 1440 x 3120 @ 505dpi, 120Hz. Note the AVD config.ini in
# docker/emulator/run.sh ALSO needs to set hw.lcd.density=505 / .width=1440
# / .height=3120 because the emulator framebuffer dimensions come from the
# AVD, not from build.prop. Both must agree to avoid resource scaling glitches.

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
# Emulator uses the goldfish/ranchu GPU stack (gfxstream → host Metal/Vulkan
# on Mac). OpenGL ES 3.2 is what the real Adreno 750 reports.

PRODUCT_PROPERTY_OVERRIDES += \
    ro.opengles.version=196610 \
    ro.hardware.egl=emulation \
    ro.hardware.gralloc=ranchu \
    debug.hwui.use_buffer_age=true \
    debug.hwui.renderer=skiagl

# ---- Telephony --------------------------------------------------------------
# Real S26 Ultra: dual-SIM (1 physical + 1 eSIM). Emulator has no real radio
# but apps consult these props before attempting calls; matching the real
# device's dual-SIM config keeps app behavior consistent.

PRODUCT_PROPERTY_OVERRIDES += \
    persist.radio.multisim.config=dsds \
    ro.telephony.default_network=33,33 \
    persist.radio.allow_pre_4g_call=1 \
    ro.config.combined_signal=true

# ---- MayaOS payload modules -------------------------------------------------
# Same Soong modules as the cuttlefish variants -- defined in this directory's
# Android.bp. Install paths owned by Soong so the device makefile only opts
# into the modules; no Samsung/OEM bloatware is bundled.

PRODUCT_PACKAGES += \
    mayaos_galaxy-s26-ultra-features.xml \
    mayaos-command-exec \
    mayaos-command-exec.rc

# ---- Custom root CA certificates -------------------------------------------
# Same wildcard pattern as cuttlefish: pick up every <hash>.0 the after-sync
# hook has staged under security/cacerts/.

MAYAOS_CA_FILES := $(wildcard device/mayaos/galaxy-s26-ultra/security/cacerts/*.0)
PRODUCT_COPY_FILES += $(foreach f,$(MAYAOS_CA_FILES),\
    $(f):system/etc/security/cacerts/$(notdir $(f)))

PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += \
    system/etc/security/cacerts/%

# ---- Locked build fingerprint (override AOSP's auto-generated one) ----------
BUILD_FINGERPRINT := samsung/s26uxxx/s26u:16/BP1A.250505.005/S948BXXU1AYA1:user/release-keys

# Intentionally empty: no Samsung/OEM bloatware is bundled into MayaOS.
# DEVICE_PACKAGE_OVERLAYS := $(LOCAL_PATH)/overlay
