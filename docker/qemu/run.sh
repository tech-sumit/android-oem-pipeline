#!/usr/bin/env bash
#
# Boot a built MayaOS profile via qemu-system-aarch64 + Apple HVF on macOS.
# This is the "skip Cuttlefish" path: the AOSP image was built FOR Cuttlefish
# (which expects vsock, virtio-fs, etc.), so we may panic at first-stage init.
# The strategy is iterative: try a minimal config, read the kernel log, fix
# what's broken in the cmdline, repeat.
#
# Required env:
#   PROFILE              -- profile bundle dir name (galaxy-s26-ultra-apple-silicon).
#
# Optional env:
#   BUNDLE_ROOT          -- where <PROFILE>/ lives. Defaults to <repo>/out/latest.
#   SMP                  -- guest vCPUs. Default 4.
#   MEM_MB               -- guest RAM MB. Default 4096.
#   ADB_PORT             -- host port mapped to guest adbd 5555. Default 6520.
#   DISPLAY_MODE         -- cocoa | none | vnc=:0. Default cocoa (a Mac window).
#   CONSOLE              -- stdio (default) | none. Use stdio to see the kernel log.
#   EXTRA_APPEND         -- extra kernel cmdline appended verbatim.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

log()  { printf '\033[1;34m[qemu]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[qemu][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[qemu][err]\033[0m %s\n' "$*" >&2; exit 1; }

: "${PROFILE:?PROFILE required (e.g. galaxy-s26-ultra-apple-silicon)}"
BUNDLE_ROOT="${BUNDLE_ROOT:-${REPO_ROOT}/out/latest}"
PROFILE_DIR="${BUNDLE_ROOT}/${PROFILE}"
IMAGES_DIR="${PROFILE_DIR}/images"

[[ -d "$IMAGES_DIR" ]] || die "no images at ${IMAGES_DIR}; run the unpack step first"

SMP="${SMP:-4}"
MEM_MB="${MEM_MB:-4096}"
ADB_PORT="${ADB_PORT:-6520}"
DISPLAY_MODE="${DISPLAY_MODE:-cocoa}"
CONSOLE="${CONSOLE:-stdio}"
EXTRA_APPEND="${EXTRA_APPEND:-}"

KERNEL="${IMAGES_DIR}/boot_unpacked/kernel"
INITRAMFS="${IMAGES_DIR}/initramfs.cpio.lz4"
SUPER="${IMAGES_DIR}/super.img"
USERDATA="${IMAGES_DIR}/userdata.img"
VBMETA="${IMAGES_DIR}/vbmeta.img"

[[ -f "$KERNEL" ]] || die "missing kernel at ${KERNEL} -- run unpack_bootimg first"

# --- 1. Combine init_boot ramdisk + vendor_boot ramdisks + bootconfig. ----
#
# Modern Android (boot image header v4 + bootconfig) expects /init to be
# obtained by concatenating, in this order:
#   1. init_boot's generic ramdisk (cpio.lz4) -- contains /init binary
#   2. vendor_boot's vendor_ramdisk00 (cpio.lz4) -- vendor first-stage
#   3. vendor_boot's vendor_ramdisk01 (cpio.lz4) -- vendor optional
#   4. bootconfig appended at end with magic trailer (TAILMAGIC + size + sum)
# bootconfig's trailer must use the kernel-recognized format
# documented at Documentation/admin-guide/bootconfig.rst.
#
# For now, we skip the bootconfig trailer (the kernel will fall back to
# parsing -append) and just concatenate the three ramdisks. If the kernel
# refuses to mount initramfs we'll add the bootconfig logic.
if [[ ! -f "$INITRAMFS" || \
      "${IMAGES_DIR}/init_boot_unpacked/ramdisk" -nt "$INITRAMFS" || \
      "${IMAGES_DIR}/vendor_boot_unpacked/vendor_ramdisk00" -nt "$INITRAMFS" ]]; then
    log "building combined initramfs.cpio.lz4"
    cat "${IMAGES_DIR}/init_boot_unpacked/ramdisk" \
        "${IMAGES_DIR}/vendor_boot_unpacked/vendor_ramdisk00" \
        "${IMAGES_DIR}/vendor_boot_unpacked/vendor_ramdisk01" \
        > "$INITRAMFS"
    log "  size: $(du -h "$INITRAMFS" | cut -f1)"
fi

# --- 2. Build the kernel cmdline. -----------------------------------------
# Started from the vendor_boot.img cmdline (visible via unpack_bootimg) plus
# qemu-virt-machine specifics (console on ttyAMA0). androidboot.* params tell
# init how to find super.img and what to set ro.bootmode etc.
#
# For Cuttlefish's MayaOS profile the boot disk index for super is the first
# virtio block device exposed by qemu, i.e. /dev/vda. We tell init this via
# androidboot.boot_devices=. The "by-name/super" symlink is created by ueventd
# from the dynamic partition metadata baked into super.img.
APPEND="
console=ttyAMA0,115200 earlyprintk=ttyAMA0,115200 earlycon=pl011,0x9000000
printk.devkmsg=on loglevel=8 ignore_loglevel
audit=1 panic=-1 8250.nr_uarts=1
binder.impl=rust cma=0 firmware_class.path=/vendor/etc/
loop.max_part=7 init=/init
androidboot.hardware=cutf_cvm
androidboot.boot_devices=4010000000.pcie
androidboot.veritymode=enforcing
androidboot.verifiedbootstate=orange
androidboot.serialno=mayaos_qemu_arm64
androidboot.lcd_density=320
androidboot.fstab_suffix=cf.ext4.cts
androidboot.slot_suffix=_a
androidboot.force_normal_boot=1
${EXTRA_APPEND}
"
APPEND="$(echo "$APPEND" | tr '\n' ' ' | tr -s ' ')"

log "kernel cmdline:"
log "  ${APPEND}"

# --- 3. Build the qemu invocation. ----------------------------------------
QEMU=(
    qemu-system-aarch64
    -name "mayaos-${PROFILE}"
    -machine virt,gic-version=3
    -cpu host
    -accel hvf
    -smp "$SMP"
    -m "$MEM_MB"
    -kernel "$KERNEL"
    -initrd "$INITRAMFS"
    -append "$APPEND"

    # Disks. virtio-blk PCI gives us /dev/vd[abc...] in the guest. Order is
    # significant: super first so it's /dev/vda (matches androidboot.boot_devices
    # heuristic).
    -drive "file=${SUPER},if=none,id=super,format=raw,cache=writeback"
    -device virtio-blk-pci,drive=super,bootindex=0
    -drive "file=${USERDATA},if=none,id=userdata,format=raw,cache=writeback"
    -device virtio-blk-pci,drive=userdata
    -drive "file=${VBMETA},if=none,id=vbmeta,format=raw,cache=writeback"
    -device virtio-blk-pci,drive=vbmeta

    # Network. user-mode networking with port-forward for adb. Guest sees the
    # qemu DHCP server at 10.0.2.2.
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ADB_PORT}-:5555"
    -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56

    # Random number generator -- Android needs entropy at boot.
    -object rng-random,filename=/dev/urandom,id=rng0
    -device virtio-rng-pci,rng=rng0

    # Touchscreen + keyboard so we can drive the UI.
    -device virtio-keyboard-pci
    -device virtio-tablet-pci

    # Display. virtio-gpu via -display cocoa for a native macOS window.
    -device virtio-gpu-pci

    # Don't bother with USB unless we add hostfwd later.
    -no-reboot
)

case "$DISPLAY_MODE" in
    cocoa) QEMU+=( -display cocoa,show-cursor=on ) ;;
    none)  QEMU+=( -display none ) ;;
    vnc=*) QEMU+=( -display "$DISPLAY_MODE" ) ;;
    *)     die "unknown DISPLAY_MODE: ${DISPLAY_MODE}" ;;
esac

if [[ "$CONSOLE" == "stdio" ]]; then
    QEMU+=( -serial mon:stdio )
elif [[ "$CONSOLE" == "none" ]]; then
    QEMU+=( -serial none -monitor none )
fi

log "launching qemu (Ctrl-A, X to quit when serial=stdio)"
log "  smp=${SMP}  mem=${MEM_MB}MB  display=${DISPLAY_MODE}  console=${CONSOLE}"
log "  adb forward: 127.0.0.1:${ADB_PORT} -> guest:5555"
log
log "command:"
printf '  %q ' "${QEMU[@]}"
echo
echo

exec "${QEMU[@]}"
