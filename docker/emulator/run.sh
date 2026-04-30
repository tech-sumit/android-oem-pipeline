#!/usr/bin/env bash
#
# Boot an Android Studio Emulator AVD from the AOSP emulator-target build
# outputs (sdk_phone64_arm64-trunk_staging-userdebug or similar) on macOS
# Apple Silicon, with HVF (Hypervisor.framework) acceleration -- so the arm64
# guest runs at near-native speed.
#
# Standard implementation -- no qemu binary patching, no shim, no `-qemu`
# passthrough. Uses the same SDK Manager / AVD Manager metadata layout that
# every Google-shipped system image (and Genymotion's local-emulator pipeline)
# uses, so the wrapper's HVF gate engages automatically.
#
# Required env:
#   PROFILE          -- profile bundle dir (under BUNDLE_ROOT) with these files:
#                         emu/kernel-ranchu, emu/system-qemu.img,
#                         emu/vendor-qemu.img, emu/ramdisk(-qemu).img,
#                         emu/userdata.img, emu/vbmeta.img,
#                         emu/encryptionkey.img, emu/advancedFeatures.ini
#
# Optional env:
#   AVD_NAME         -- defaults to mayaos-${PROFILE}
#   BUNDLE_ROOT      -- defaults to <repo>/out/latest
#   API_LEVEL        -- defaults to 36.1 (must be a level the SDK has installed
#                       under platforms/; mirrors stock GApps path so HVF gate
#                       can use the same code paths)
#   LCD_DENSITY      -- defaults to 560 (2x density Pixel 7 Pro-class device)
#   LCD_WIDTH        -- defaults to 1440
#   LCD_HEIGHT       -- defaults to 3120
#   GUEST_RAM_MB     -- defaults to 4096
#   GUEST_VM_HEAP    -- defaults to 384 (per-app VM heap, MB)
#   ANDROID_SDK_ROOT -- defaults to ~/Library/Android/sdk
#   AVD_HOME         -- defaults to ~/.android/avd
#   GPU_MODE         -- swiftshader_indirect | host. Default swiftshader_indirect
#                       (host needs Metal-on-Vulkan and is touchier under HVF).
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

log()  { printf '\033[1;34m[emu]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[emu][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[emu][err]\033[0m %s\n' "$*" >&2; exit 1; }

: "${PROFILE:?PROFILE required}"

BUNDLE_ROOT="${BUNDLE_ROOT:-${REPO_ROOT}/out/latest}"
PROFILE_DIR="${BUNDLE_ROOT}/${PROFILE}"
EMU_DIR="${PROFILE_DIR}/emu"

[[ -d "$EMU_DIR" ]] || die "no emulator artifacts at ${EMU_DIR}; run 'make r2-fetch-latest PROFILES=${PROFILE}' or copy from pod"

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}"
AVD_HOME="${AVD_HOME:-${HOME}/.android/avd}"
AVD_NAME="${AVD_NAME:-mayaos-${PROFILE}}"
API_LEVEL="${API_LEVEL:-36.1}"
LCD_DENSITY="${LCD_DENSITY:-560}"
LCD_WIDTH="${LCD_WIDTH:-1440}"
LCD_HEIGHT="${LCD_HEIGHT:-3120}"
GUEST_RAM_MB="${GUEST_RAM_MB:-4096}"
GUEST_VM_HEAP="${GUEST_VM_HEAP:-384}"
GPU_MODE="${GPU_MODE:-swiftshader_indirect}"

EMULATOR_BIN="${ANDROID_SDK_ROOT}/emulator/emulator"
AVDMANAGER_BIN="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/avdmanager"
[[ -x "$EMULATOR_BIN" ]]   || die "emulator missing at ${EMULATOR_BIN}; install Android Studio + the emulator package"
[[ -x "$AVDMANAGER_BIN" ]] || die "avdmanager missing at ${AVDMANAGER_BIN}; install cmdline-tools (sdkmanager 'cmdline-tools;latest')"

# --- Lay out the system-image dir in the canonical SDK location. ---------
# The Android SDK / emulator wrapper expects images at:
#   ${SDK}/system-images/android-<API>/<tag>/<abi>/
# stock GApps lives at:
#   ${SDK}/system-images/android-36.1/google_apis_playstore/arm64-v8a/
# We mirror that layout so:
#   1. sdkmanager --list_installed picks our package up cleanly.
#   2. avdmanager create avd --package "system-images;android-XX;mayaos;arm64-v8a"
#      generates a config.ini that satisfies the wrapper's HVF gate.
SYSIMG_DIR="${ANDROID_SDK_ROOT}/system-images/android-${API_LEVEL}/mayaos/arm64-v8a"
SYSIMG_PKG="system-images;android-${API_LEVEL};mayaos;arm64-v8a"
mkdir -p "$SYSIMG_DIR"

# Hardlink (or copy if cross-fs) artifacts to their right home.
link_or_copy() {
    local src="$1" dst="$2"
    [[ -f "$src" ]] || { warn "missing source ${src}; skipping"; return; }
    rm -f "$dst"
    if ln "$src" "$dst" 2>/dev/null; then
        log "  hardlink: $(basename "$dst")"
    else
        cp "$src" "$dst"
        log "  copy:     $(basename "$dst")"
    fi
}

# NOTE: AOSP `sdk_phone64_arm64` emits two flavors:
#   system.img      -- flat /system partition only
#   system-qemu.img -- /system + /system_ext + /product + /vendor merged into a
#                       single dynamic-partition super.img blob, ranchu-style
# The Android Studio Emulator with `DynamicPartition = on` (in
# advancedFeatures.ini) expects the merged variant as `system.img`. Same for
# vendor-qemu.img -> vendor.img and ramdisk-qemu.img -> ramdisk.img.
pick_qemu_or_flat() {
    local qemu_name="$1" flat_name="$2"
    if [[ -f "${EMU_DIR}/${qemu_name}" ]]; then
        printf '%s' "${EMU_DIR}/${qemu_name}"
    else
        printf '%s' "${EMU_DIR}/${flat_name}"
    fi
}

log "wiring shared system images into ${SYSIMG_DIR}"
link_or_copy "${EMU_DIR}/kernel-ranchu"                                       "${SYSIMG_DIR}/kernel-ranchu"
link_or_copy "$(pick_qemu_or_flat system-qemu.img system.img)"                "${SYSIMG_DIR}/system.img"
link_or_copy "$(pick_qemu_or_flat vendor-qemu.img vendor.img)"                "${SYSIMG_DIR}/vendor.img"
link_or_copy "$(pick_qemu_or_flat ramdisk-qemu.img ramdisk.img)"              "${SYSIMG_DIR}/ramdisk.img"
link_or_copy "${EMU_DIR}/userdata.img"                                        "${SYSIMG_DIR}/userdata.img"
link_or_copy "${EMU_DIR}/encryptionkey.img"                                   "${SYSIMG_DIR}/encryptionkey.img"
[[ -f "${EMU_DIR}/vbmeta.img" ]]                  && link_or_copy "${EMU_DIR}/vbmeta.img"                  "${SYSIMG_DIR}/vbmeta.img"
[[ -f "${EMU_DIR}/advancedFeatures.ini" ]]        && link_or_copy "${EMU_DIR}/advancedFeatures.ini"        "${SYSIMG_DIR}/advancedFeatures.ini"
[[ -f "${EMU_DIR}/kernel_cmdline.txt" ]]          && link_or_copy "${EMU_DIR}/kernel_cmdline.txt"          "${SYSIMG_DIR}/kernel_cmdline.txt"
[[ -f "${EMU_DIR}/VerifiedBootParams.textproto" ]] && link_or_copy "${EMU_DIR}/VerifiedBootParams.textproto" "${SYSIMG_DIR}/VerifiedBootParams.textproto"

# --- The HVF gate. -------------------------------------------------------
# `external/qemu/android-qemu2-glue/main.cpp` (~line 2399) only passes
# `-enable-hvf` to QEMU if BOTH:
#     avdInfo_getApiLevel(avd) >= 21
#     strcmp(avdInfo_getTargetAbi(avd), "arm64-v8a") == 0
#
# `avdInfo_getTargetAbi` is implemented in `external/qemu/android/avd/info.c`
# (`_avdInfo_extractBuildProperties`) and reads `ro.product.cpu.abi` from a
# top-level `build.prop` in the system-image dir. If that file is missing
# (which is the default for AOSP `sdk_phone64_arm64` outputs) the function
# silently falls back to `"armeabi"` and HVF gets skipped -- the emulator
# falls back to TCG (~10x slower, "x86 is 10x faster" dialog appears).
#
# Newer build artifacts (after pipeline/hooks/after-build.sh added emu/
# bundling) ship build.prop / source.properties / package.xml directly. We
# prefer those when present so the SDK metadata matches whatever the build
# emitted; fall back to the regenerated minimal versions for older bundles.
copy_or_generate_metadata() {
    local src="${EMU_DIR}/$1" dst="${SYSIMG_DIR}/$1"
    if [[ -f "$src" ]]; then
        cp "$src" "$dst"
        log "  bundled:  $1 (from build artifacts)"
        return 0
    fi
    return 1
}

if ! copy_or_generate_metadata build.prop; then
    log "writing build.prop (HVF gate -- ro.product.cpu.abi) [legacy bundle]"
    cat > "${SYSIMG_DIR}/build.prop" <<EOF
####################################
# MayaOS arm64-v8a sysimg metadata for the Android emulator wrapper.
# These keys gate HVF acceleration on Apple Silicon (see info.c
# _avdInfo_extractBuildProperties + main.cpp HVF check).
# Generated by docker/emulator/run.sh (build artifacts pre-date emu/
# metadata bundling -- new builds ship build.prop in the bundle).
####################################
ro.product.cpu.abi=arm64-v8a
ro.product.cpu.abilist=arm64-v8a
ro.product.cpu.abilist32=
ro.product.cpu.abilist64=arm64-v8a
ro.system.product.cpu.abilist=arm64-v8a
ro.system.product.cpu.abilist32=
ro.system.product.cpu.abilist64=arm64-v8a
ro.build.version.sdk=36
ro.build.version.sdk_full=${API_LEVEL}
ro.build.version.release=16
ro.system.build.version.sdk=36
ro.system.build.version.sdk_full=${API_LEVEL}
ro.product.system.brand=mayaos
ro.product.system.device=galaxy-s26-ultra
ro.product.system.manufacturer=MayaOS
ro.product.system.model=Galaxy S26 Ultra
ro.product.system.name=mayaos_galaxy_s26_ultra
EOF
fi

# Standard SDK metadata files. sdkmanager --list_installed reads package.xml
# to enumerate installed system images; avdmanager create avd uses the
# `path` attribute as the --package handle.
if ! copy_or_generate_metadata source.properties \
   || ! copy_or_generate_metadata package.xml; then
    log "writing source.properties + package.xml [legacy bundle]"
    cat > "${SYSIMG_DIR}/source.properties" <<EOF
Pkg.Desc=MayaOS System Image arm64-v8a built from AOSP trunk_staging.
Pkg.Revision=1
Pkg.Dependencies=emulator#35.4.9
AndroidVersion.ApiLevel=${API_LEVEL%.*}
AndroidVersion.IsBaseSdk=true
SystemImage.Abi=arm64-v8a
SystemImage.TagId=mayaos
SystemImage.TagDisplay=MayaOS
SystemImage.GpuSupport=true
Addon.VendorId=mayaos
Addon.VendorDisplay=MayaOS
EOF

    cat > "${SYSIMG_DIR}/package.xml" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02"
                xmlns:ns12="http://schemas.android.com/sdk/android/repo/sys-img2/04">
    <localPackage path="${SYSIMG_PKG}" obsolete="false">
        <type-details xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="ns12:sysImgDetailsType">
            <api-level>${API_LEVEL%.*}</api-level>
            <base-extension>true</base-extension>
            <tag>
                <id>mayaos</id>
                <display>MayaOS</display>
            </tag>
            <vendor>
                <id>mayaos</id>
                <display>MayaOS</display>
            </vendor>
            <abi>arm64-v8a</abi>
            <abis>arm64-v8a</abis>
        </type-details>
        <revision><major>1</major></revision>
        <display-name>MayaOS ARM 64 v8a System Image</display-name>
        <dependencies>
            <dependency path="emulator">
                <min-revision><major>35</major><minor>4</minor><micro>9</micro></min-revision>
            </dependency>
        </dependencies>
    </localPackage>
</ns2:repository>
EOF
fi

# --- Create the AVD via the official avdmanager. -------------------------
# This is the standard, Google-recommended way -- avdmanager parses our
# package.xml, validates ABI/API, and writes a config.ini that the emulator
# wrapper accepts without further patching. Uses pixel_7_pro as the device
# profile (closest stock match for an S26 Ultra-class screen).
log "(re)creating AVD '${AVD_NAME}' via avdmanager"
rm -rf "${AVD_HOME}/${AVD_NAME}.avd" "${AVD_HOME}/${AVD_NAME}.ini"
"$AVDMANAGER_BIN" create avd \
    --name "$AVD_NAME" \
    --package "$SYSIMG_PKG" \
    --abi arm64-v8a \
    --device "pixel_7_pro" \
    --force <<< "no" >/dev/null

# Override the auto-generated config.ini to pin the screen size, GPU mode,
# RAM, and our display name. Everything else stays as avdmanager wrote it.
CFG="${AVD_HOME}/${AVD_NAME}.avd/config.ini"
[[ -f "$CFG" ]] || die "avdmanager didn't create ${CFG}; check 'sdkmanager --list_installed' for ${SYSIMG_PKG}"

# Patch in our overrides (sed -E with anchored keys avoids partial matches).
patch_kv() {
    local key="$1" val="$2"
    if grep -qE "^${key}=" "$CFG"; then
        sed -i '' -E "s|^${key}=.*|${key}=${val}|" "$CFG"
    else
        printf '%s=%s\n' "$key" "$val" >> "$CFG"
    fi
}
patch_kv 'avd.ini.displayname'  "MayaOS (${PROFILE})"
patch_kv 'hw.gpu.enabled'       'yes'
patch_kv 'hw.gpu.mode'          "$GPU_MODE"
patch_kv 'hw.lcd.density'       "$LCD_DENSITY"
patch_kv 'hw.lcd.width'         "$LCD_WIDTH"
patch_kv 'hw.lcd.height'        "$LCD_HEIGHT"
patch_kv 'hw.ramSize'           "${GUEST_RAM_MB}"
patch_kv 'vm.heapSize'          "${GUEST_VM_HEAP}"
patch_kv 'tag.id'               'mayaos'
patch_kv 'tag.display'          'MayaOS'

# --- Launch. --------------------------------------------------------------
# -accel on:        let the wrapper pick HVF (gated by build.prop ABI key
#                   above; will engage now that the gate passes).
# -no-snapshot:     cold boot, no save/load -- avoids snapshot version
#                   mismatch when we re-link images.
# -no-boot-anim:    shave a few seconds off boot.
# -gpu host:        OpenGL ES via Apple Metal -> HVF guest. swiftshader_indirect
#                   is the safe fallback if Metal/Vulkan path misbehaves.
# -netfast:         user-mode networking with port-forwards.
# -ports 5554,5555: standard adb console + adb daemon ports.
log
log "launching emulator: AVD=${AVD_NAME}"
log "  ANDROID_AVD_HOME=${AVD_HOME}"
log "  emulator binary:  ${EMULATOR_BIN}"
log "  hypervisor:       HVF (engaged via standard SDK metadata + build.prop)"
log "  GPU mode:         ${GPU_MODE}"

# Wipe cached hardware-qemu.ini so the wrapper regenerates fresh from our
# config.ini every run.
rm -f "${AVD_HOME}/${AVD_NAME}.avd/hardware-qemu.ini"

ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT" \
ANDROID_AVD_HOME="$AVD_HOME" \
exec "$EMULATOR_BIN" \
    -avd "$AVD_NAME" \
    -accel on \
    -gpu "$GPU_MODE" \
    -no-snapshot \
    -no-boot-anim \
    -netfast \
    -ports 5554,5555 \
    -show-kernel \
    -verbose
