#
# MayaOS Device Farm - Samsung Galaxy S26 Ultra arm64 spoof profile.
#
# This variant targets arm64 Cuttlefish so the produced image can be consumed by
# Apple Silicon runtime paths. The x86_64 sibling remains the Intel GPU host
# build.
#
# Lunch:   mayaos_cf_s26ultra_arm64-trunk_staging-userdebug
# Output:  out/target/product/vsoc_arm64/
#

$(call inherit-product, device/google/cuttlefish/vsoc_arm64/phone/aosp_cf.mk)

PRODUCT_NAME         := mayaos_cf_s26ultra_arm64
PRODUCT_DEVICE       := vsoc_arm64
PRODUCT_BRAND        := samsung
PRODUCT_MODEL        := SM-S948B
PRODUCT_MANUFACTURER := samsung

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

PRODUCT_PROPERTY_OVERRIDES += \
    ro.oem.flavor=galaxy-s26-ultra \
    ro.oem.build.tag=mayaos.devicefarm.s26ultra.arm64 \
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

PRODUCT_PROPERTY_OVERRIDES += \
    ro.opengles.version=196610 \
    ro.hardware.egl=emulation \
    ro.hardware.gralloc=ranchu \
    debug.hwui.use_buffer_age=true \
    debug.hwui.renderer=skiagl

PRODUCT_PROPERTY_OVERRIDES += \
    persist.radio.multisim.config=dsds \
    ro.telephony.default_network=33,33 \
    persist.radio.allow_pre_4g_call=1 \
    ro.config.combined_signal=true

# MayaOS payload modules (defined in this directory's Android.bp).
# Install paths are owned by Soong so PRODUCT_PACKAGES is the only opt-in.
PRODUCT_PACKAGES += \
    mayaos_galaxy-s26-ultra-features.xml \
    mayaos-command-exec \
    mayaos-command-exec.rc

MAYAOS_CA_FILES := $(wildcard device/mayaos/galaxy-s26-ultra/security/cacerts/*.0)
PRODUCT_COPY_FILES += $(foreach f,$(MAYAOS_CA_FILES),\
    $(f):system/etc/security/cacerts/$(notdir $(f)))

# Allow MayaOS roots to land in /system/etc/security/cacerts/ alongside the
# GSI's bundle without violating generic_system.mk's artifact path requirement.
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += \
    system/etc/security/cacerts/%

BUILD_FINGERPRINT := samsung/s26uxxx/s26u:16/BP1A.250505.005/S948BXXU1AYA1:user/release-keys

# Intentionally empty: no Samsung/OEM bloatware is bundled into MayaOS.
# DEVICE_PACKAGE_OVERLAYS := $(LOCAL_PATH)/overlay
