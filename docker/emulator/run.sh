#!/usr/bin/env bash
#
# Boot an Android Studio Emulator AVD from the AOSP emulator-target build
# outputs (sdk_phone64_arm64-trunk_staging-userdebug or similar).
#
# Unlike Cuttlefish, the Android Studio emulator on macOS uses Apple HVF
# directly, so an arm64 guest runs at near-native speed (no Rosetta, no TCG).
# This is the "fastest local boot" option for a built MayaOS image.
#
# Required env:
#   PROFILE          -- profile bundle dir (under BUNDLE_ROOT) with these files:
#                         emu_kernel  (named kernel-ranchu in AOSP output)
#                         emu_system.img
#                         emu_vendor.img
#                         emu_userdata.img
#                         emu_ramdisk.img
#                         emu_vbmeta.img       (optional)
#                         emu_advancedFeatures.ini (optional, copied from AOSP)
#
# Optional env:
#   AVD_NAME         -- defaults to mayaos-${PROFILE}
#   BUNDLE_ROOT      -- defaults to <repo>/out/latest
#   LCD_DENSITY      -- defaults to 320 (xhdpi)
#   LCD_WIDTH        -- defaults to 1080
#   LCD_HEIGHT       -- defaults to 1920
#   GUEST_RAM_MB     -- defaults to 4096
#   GUEST_VM_HEAP    -- defaults to 256 (per-app VM heap, MB)
#   ANDROID_SDK_ROOT -- defaults to ~/Library/Android/sdk
#   AVD_HOME         -- defaults to ~/.android/avd
#   GPU_MODE         -- swiftshader_indirect | host. Default host (HVF).
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
LCD_DENSITY="${LCD_DENSITY:-320}"
LCD_WIDTH="${LCD_WIDTH:-1080}"
LCD_HEIGHT="${LCD_HEIGHT:-1920}"
GUEST_RAM_MB="${GUEST_RAM_MB:-4096}"
GUEST_VM_HEAP="${GUEST_VM_HEAP:-256}"
GPU_MODE="${GPU_MODE:-host}"

EMULATOR_BIN="${ANDROID_SDK_ROOT}/emulator/emulator"
[[ -x "$EMULATOR_BIN" ]] || die "emulator missing at ${EMULATOR_BIN}; install Android Studio + the emulator package"

# --- Lay out the AVD directory. -------------------------------------------
# The Android emulator expects:
#   ${AVD_HOME}/${AVD_NAME}.ini    -- pointer file (path = <AVD_HOME>/<NAME>.avd)
#   ${AVD_HOME}/${AVD_NAME}.avd/   -- the AVD itself
#     config.ini                   -- hardware/display/RAM/storage settings
#     kernel-ranchu                -- the ranchu (qemu2) ARM64 kernel
#     system.img                   -- system partition image
#     vendor.img                   -- vendor partition
#     userdata.img                 -- /data; auto-resized on first boot
#     ramdisk.img                  -- initramfs
#     vbmeta.img                   -- AVB metadata (optional)
#     advancedFeatures.ini         -- engine-level toggles (optional)
AVD_PATH="${AVD_HOME}/${AVD_NAME}.avd"
mkdir -p "$AVD_PATH" "$AVD_HOME"

cat > "${AVD_HOME}/${AVD_NAME}.ini" <<EOF
avd.ini.encoding=UTF-8
path=${AVD_PATH}
path.rel=avd/${AVD_NAME}.avd
target=android-Baklava
EOF

# Hardlink (or copy if cross-fs) the emu artifacts into the AVD dir.
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

log "wiring artifacts into ${AVD_PATH}"
link_or_copy "${EMU_DIR}/kernel-ranchu" "${AVD_PATH}/kernel-ranchu"
link_or_copy "${EMU_DIR}/system.img"    "${AVD_PATH}/system.img"
link_or_copy "${EMU_DIR}/vendor.img"    "${AVD_PATH}/vendor.img"
link_or_copy "${EMU_DIR}/userdata.img"  "${AVD_PATH}/userdata.img"
link_or_copy "${EMU_DIR}/ramdisk.img"   "${AVD_PATH}/ramdisk.img"
[[ -f "${EMU_DIR}/vbmeta.img" ]] && link_or_copy "${EMU_DIR}/vbmeta.img" "${AVD_PATH}/vbmeta.img"
[[ -f "${EMU_DIR}/advancedFeatures.ini" ]] && \
    link_or_copy "${EMU_DIR}/advancedFeatures.ini" "${AVD_PATH}/advancedFeatures.ini"

# AVD config. These mirror what `avdmanager create avd` writes for an
# arm64 phone, with our custom image pinned via "image.sysdir.1".
cat > "${AVD_PATH}/config.ini" <<EOF
AvdId=${AVD_NAME}
PlayStore.enabled=false
abi.type=arm64-v8a
avd.ini.displayname=MayaOS (${PROFILE})
avd.ini.encoding=UTF-8
disk.dataPartition.size=8G
disk.systemPartition.size=4G
disk.snapshots.size=4G
fastboot.chosenSnapshotFile=
fastboot.forceChosenSnapshotBoot=no
fastboot.forceColdBoot=no
fastboot.forceFastBoot=yes
hw.accelerometer=yes
hw.audioInput=yes
hw.battery=yes
hw.camera.back=virtualscene
hw.camera.front=emulated
hw.cpu.arch=arm64
hw.cpu.model=cortex-a73
hw.cpu.ncore=4
hw.dPad=no
hw.device.hash2=MD5:bc5032b2a871da511332401af3ac6bb0
hw.device.manufacturer=mayaos
hw.device.name=mayaos_${PROFILE}
hw.gps=yes
hw.gpu.enabled=yes
hw.gpu.mode=${GPU_MODE}
hw.initialOrientation=Portrait
hw.keyboard=yes
hw.lcd.density=${LCD_DENSITY}
hw.lcd.height=${LCD_HEIGHT}
hw.lcd.width=${LCD_WIDTH}
hw.mainKeys=no
hw.ramSize=${GUEST_RAM_MB}
hw.sdCard=yes
hw.sensors.orientation=yes
hw.sensors.proximity=yes
hw.trackBall=no
runtime.network.latency=none
runtime.network.speed=full
sdcard.size=512M
showDeviceFrame=no
skin.dynamic=yes
skin.name=1080x1920
skin.path=_no_skin
tag.display=Default
tag.id=default
vm.heapSize=${GUEST_VM_HEAP}
EOF

# --- Launch. --------------------------------------------------------------
# -no-snapshot:       cold boot (no save/load); avoids snapshot-version mismatch
#                     when we swap the system image underneath.
# -no-boot-anim:      shave a few seconds off boot; we don't need bootanim.
# -accel on:          enable hypervisor (HVF on macOS, KVM on Linux). Note: the
#                     emulator binary's -accel flag accepts on/off/auto only --
#                     '-accel hvf' is rejected as invalid.
# -gpu host:          OpenGL ES via Apple Metal -> HVF guest. `swiftshader_indirect`
#                     is the safe fallback if -gpu host doesn't work.
# -netfast:           fast user-mode networking with port-forward.
# -ports 5554,5555:   adb console on 5554, adb on 5555. Standard pair the
#                     android-debug-bridge daemon scans by default.
log
log "launching emulator: AVD=${AVD_NAME}"
log "  ANDROID_AVD_HOME=${AVD_HOME}"
log "  emulator binary: ${EMULATOR_BIN}"

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
