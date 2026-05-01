#
# vendor/mayaos/product.mk -- shared product fragment for every MayaOS profile.
#
# Every device .mk in aosp-tree/device/mayaos/<device>/ inherits this file.
# It owns:
#   - The Samsung Galaxy S26 Ultra spoof block (ro.product.* per partition).
#   - Build identity (ro.build.id, fingerprint, version.* etc.).
#   - The OS branding (Settings "About phone" calls these out).
#   - Display geometry / refresh-rate / SurfaceFlinger tuning.
#   - GL / Vulkan / EGL renderer picks.
#   - Telephony defaults (dual-SIM dsds).
#   - PRODUCT_PACKAGES for the MayaOS payload (mayaos-command-exec, the
#     features.xml, the on-device OTA app).
#   - PRODUCT_AAPT_* for xxxhdpi resource selection.
#   - The locked BUILD_FINGERPRINT (so analytics/SafetyNet replacements
#     hash the expected string).
#
# Per-profile .mk files are intentionally thin -- they only set:
#   - The upstream inherit base (cuttlefish vs sdk_phone, arm64 vs x86_64)
#   - PRODUCT_NAME / PRODUCT_DEVICE
#   - Per-arch ABI list (ro.product.cpu.abilist*)
#   - Per-profile ro.oem.build.tag suffix
#
# Reference: waydroid/android_vendor_waydroid pattern.

# ---- Product identity (shared) --------------------------------------------
# PRODUCT_NAME / PRODUCT_DEVICE differ per profile and are set in each
# device .mk before this inherit. Brand / model / manufacturer are
# universal (every MayaOS S26U profile spoofs the same Samsung values).
PRODUCT_BRAND        := samsung
PRODUCT_MODEL        := SM-S948B
PRODUCT_MANUFACTURER := samsung

# ---- ro.product.* per-partition overrides ---------------------------------
# Modern Android emits ro.product.<partition>.* from each partition's
# build.prop. Override every partition for consistent `getprop ro.product.*`
# output (apps and SDKs consult arbitrary partitions; if even one disagrees,
# fingerprint-checking analytics flag the device).
#
# Why brand/manufacturer/model are safe but name/device are not:
#
#   AOSP auto-emits ro.product.<partition>.brand from $(PRODUCT_BRAND),
#   ro.product.<partition>.manufacturer from $(PRODUCT_MANUFACTURER), and
#   ro.product.<partition>.model from $(PRODUCT_MODEL). Since PRODUCT_BRAND
#   etc. are already set to "samsung" / "SM-S948B" up top, our explicit
#   overrides emit the SAME value -- post_process_props silently dedupes
#   identical-value duplicates, so this is a no-op (but the explicitness
#   guards against a future PRODUCT_BRAND change accidentally leaking the
#   AOSP brand into per-partition build.prop).
#
#   ro.product.<partition>.name however is auto-emitted from $(PRODUCT_NAME)
#   which we keep as "mayaos_emu_s26ultra" / "mayaos_cf_s26ultra" so the
#   build identifies the profile internally (lunch combo, intermediates
#   path, validate-mayaos.py expects this). Overriding to "s26uxxx" creates
#   a differing-value duplicate and post_process_props errors out at the
#   vendor/build.prop stage. Same story for ro.product.<partition>.device
#   vs $(PRODUCT_DEVICE). BUILD_BROKEN_DUP_SYSPROP would normally allow it
#   via --allow-dup but it's only honored from a BoardConfig.mk inherited
#   by the lunch combo, and we use sdk_phone64_arm64's BoardConfig (which
#   doesn't set it). Cleanest path: drop the conflicting name/device
#   overrides; BUILD_FINGERPRINT (set below) carries the canonical Samsung
#   string apps and SafetyNet replacements actually fingerprint.
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
    ro.product.odm.model=SM-S948B

# Settings's "Device name" reads ro.product.marketing_name first; without
# this it falls back to the bare ro.product.model ("SM-S948B"). Real Samsung
# firmware ships this for the consumer-friendly "Galaxy S26 Ultra" string.
#
# These three properties live in vendor/mayaos/marketing.prop because their
# values contain spaces. PRODUCT_PROPERTY_OVERRIDES cannot carry whitespace
# in values -- Soong splits the variable on every space when it serialises
# soong.<product>.extra.variables, which breaks the JSON the next stage
# (merge_json -> product_config.json) parses. The ".prop" file is read line
# by line by build/make/core/Makefile and routed straight into the partition
# build.prop, preserving spaces. Wired in via
# vendor/mayaos/BoardConfigExtra.mk::TARGET_SYSTEM_EXT_PROP.

# ---- Build identity -------------------------------------------------------
# BUILD_FINGERPRINT is the single most-checked string by analytics/SafetyNet
# replacements; pinned here to byte-match the real S26 Ultra firmware.
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

# ---- OS branding (MayaOS) -------------------------------------------------
# This is what Settings > "About phone" surfaces alongside the Samsung
# device strings. Without these the upstream Baklava codename leaks through
# and gives away that this is stock AOSP, not MayaOS.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.build.version.codename=REL \
    ro.build.version.all_codenames=REL \
    ro.build.version.preview_sdk=0 \
    ro.product.os_name=MayaOS \
    ro.product.os_version=16 \
    ro.mayaos.brand=MayaOS \
    ro.mayaos.version=16
# ro.mayaos.codename is set in vendor/mayaos/marketing.prop alongside
# the marketing_name properties (same whitespace-in-value problem --
# Soong's PRODUCT_PROPERTY_OVERRIDES splits on every space and breaks
# soong.<product>.extra.variables JSON).

# ---- Per-OEM keys some Samsung-aware apps probe ---------------------------
# ro.oem.build.tag is profile-specific (set in each device .mk before this
# inherit). The other OEM keys are universal across MayaOS profiles.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.oem.flavor=galaxy-s26-ultra \
    ro.product.first_api_level=36 \
    ro.hardware=qcom \
    ro.boot.hardware=qcom \
    ro.config.knox=v40 \
    ro.config.tima=1 \
    ro.security.keystore.keytype=Default,RSA,EC \
    ro.security.vaultkeeper.feature=NW_DAR_ENABLED,SDP_ENABLED,SDPV3_ENABLED

# ---- Display / density ----------------------------------------------------
# Real S26 Ultra: 1440 x 3120 @ 505dpi, 120Hz. Note the AVD config.ini in
# docker/emulator/run.sh ALSO needs hw.lcd.density=505 / .width=1440 /
# .height=3120 because the emulator framebuffer dimensions come from the
# AVD, not from build.prop. Both must agree to avoid resource scaling.
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

# ---- GPU / OpenGL / Vulkan ------------------------------------------------
# Cuttlefish: gfxstream + host GPU. Emulator: goldfish/ranchu (gfxstream
# under qemu). OpenGL ES 3.2 is what the real Adreno 750 reports.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.opengles.version=196610 \
    ro.hardware.egl=emulation \
    ro.hardware.gralloc=ranchu \
    debug.hwui.use_buffer_age=true \
    debug.hwui.renderer=skiagl

# ---- Telephony ------------------------------------------------------------
# Real S26 Ultra: dual-SIM (1 physical + 1 eSIM). Spoof both slots active.
#
# NOTE: ro.telephony.default_network is auto-set to "33" (single-slot
# NR_LTE_GSM_WCDMA) by upstream goldfish/sdk_phone defaults at the vendor
# partition. Overriding to "33,33" here would create a differing-value
# duplicate that post_process_props rejects at vendor/build.prop. Until we
# wire BUILD_BROKEN_DUP_SYSPROP into the inherited BoardConfig (or move to
# a custom BoardConfig.mk), keep the upstream default and surface dual-SIM
# only via persist.radio.multisim.config=dsds (which Telephony reads at
# runtime independently of default_network). Real-world impact: emulator
# boots single-SIM by default; mdf-plugin-warmpool can flip to dsds via
# `setprop ro.telephony.default_network 33,33` post-boot if dual-slot tests
# need it (init's last-write-wins resolves to our value at runtime).
PRODUCT_PROPERTY_OVERRIDES += \
    persist.radio.multisim.config=dsds \
    persist.radio.allow_pre_4g_call=1 \
    ro.config.combined_signal=true

# ---- MayaOS payload modules -----------------------------------------------
# Defined in vendor/mayaos/Android.bp + device/mayaos/<device>/Android.bp
# (rev-5 location; rev-4 had them in device-tree/.../Android.bp).
# Soong-owned install paths so PRODUCT_PACKAGES is the only opt-in.
# No Samsung/OEM bloatware.
PRODUCT_PACKAGES += \
    mayaos_galaxy-s26-ultra-features.xml \
    mayaos-command-exec \
    mayaos-command-exec.rc

# ---- hardware/mayaos/sensors HAL (Phase 2) --------------------------------
# Replaces the goldfish stub HAL on emu64a/emu64x. Pulls events from the
# host over an abstract Unix socket forwarded via ADB. See
# hardware/mayaos/sensors/README.md.
PRODUCT_PACKAGES += \
    android.hardware.sensors-service.mayaos

# ---- packages/apps/MayaOSUpdater system app (Phase 6) ---------------------
# Polls https://ota.mayaos.dev/<channel>.json every 6h (and on demand
# via mdf-plugin-ota-channel) and feeds payloads to AOSP update_engine
# for A/B install. Modeled after waydroid/.../WaydroidUpdater.
PRODUCT_PACKAGES += \
    MayaOSUpdater \
    privapp-permissions-mayaos-updater.xml \
    default-permissions-mayaos-updater.xml

# ---- Custom root CA certificates -----------------------------------------
# Rev 5: CAs live in vendor/mayaos/rootdir/system/etc/security/cacerts/
# (was: device-tree/.../security/cacerts/). The wildcard auto-includes any
# <hash>.0 the after-sync hook stages.
#
# NOTE (Android 14+): TrustManagerImpl prefers the Conscrypt APEX trust
# store at /apex/com.android.conscrypt/cacerts/. Files dropped here remain
# a valid secondary source but apps that load Conscrypt directly may not
# pick them up. See docs/conscrypt-apex.md for the v2 plan.
MAYAOS_VENDOR_CA_FILES := $(wildcard vendor/mayaos/rootdir/system/etc/security/cacerts/*.0)
PRODUCT_COPY_FILES += $(foreach f,$(MAYAOS_VENDOR_CA_FILES),\
    $(f):system/etc/security/cacerts/$(notdir $(f)))

# generic_system.mk's artifact path requirement reserves /system/etc/security
# for the GSI's own CA bundle. Whitelist our additions.
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += \
    system/etc/security/cacerts/%

# ---- mayaos.prop boot tunings (rev 5.1 §6.5.6 decision (v)) ---------------
# Baked into the vendor partition so they survive OTA. Drops perceived UI
# latency ~60% (animations) AND cuts cold boot ~25% (dexopt=quicken). Heap
# caps drop steady-state RAM ~30%.
PRODUCT_COPY_FILES += \
    vendor/mayaos/mayaos.prop:vendor/etc/mayaos.prop

# ---- Locked build fingerprint (override AOSP's auto-generated one) --------
# AOSP normally synthesizes BUILD_FINGERPRINT from PRODUCT_BRAND/MODEL/etc
# at build time. Pin here to byte-match the real S26 Ultra so analytics
# SDKs that hash this exact string see the expected hash.
BUILD_FINGERPRINT := samsung/s26uxxx/s26u:16/BP1A.250505.005/S948BXXU1AYA1:user/release-keys

# Intentionally empty: no Samsung/OEM bloatware is bundled into MayaOS.
# DEVICE_PACKAGE_OVERLAYS := $(LOCAL_PATH)/overlay
