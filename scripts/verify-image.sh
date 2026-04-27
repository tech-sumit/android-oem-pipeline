#!/usr/bin/env bash
#
# Verify that a built CustomOS image carries our custom CA(s) and OEM branding.
# Run this AFTER you've booted the image with `launch_cvd` (Cuttlefish runtime).
#
# Checks:
#   1. adb is connected to a cuttlefish device
#   2. ro.product.brand        == CustomOS
#   3. ro.oem.flavor           == customos
#   4. /system/etc/security/cacerts/<hash>.0 exists for every CA in ca/
#   5. The CA on the device is byte-identical to the one in ca/
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CA_DIR="${REPO_ROOT}/ca"

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(ts)" "$*"; }
ok()   { printf '\033[1;32m[%s] OK\033[0m   %s\n' "$(ts)" "$*"; }
fail() { printf '\033[1;31m[%s] FAIL\033[0m %s\n' "$(ts)" "$*" >&2; }

command -v adb >/dev/null 2>&1 || { fail "adb not on PATH (apt install android-tools-adb)"; exit 1; }
command -v openssl >/dev/null 2>&1 || { fail "openssl not on PATH"; exit 1; }

log "waiting for adb device (timeout 60s)"
adb wait-for-device
deviceline=$(adb devices | grep -E '\bdevice\b' | head -1) || true
[[ -n "${deviceline:-}" ]] || { fail "no adb device after 60s"; exit 1; }
log "adb device: $deviceline"

failures=0

# 1. Branding props.
log "checking branding props"
brand=$(adb shell getprop ro.product.brand | tr -d '\r')
flavor=$(adb shell getprop ro.oem.flavor | tr -d '\r')
build_tag=$(adb shell getprop ro.oem.build.tag | tr -d '\r')

if [[ "$brand" == "CustomOS" ]]; then ok "ro.product.brand=$brand"
else fail "ro.product.brand=$brand (expected CustomOS)"; failures=$((failures+1)); fi

if [[ "$flavor" == "customos" ]]; then ok "ro.oem.flavor=$flavor"
else fail "ro.oem.flavor=$flavor (expected customos)"; failures=$((failures+1)); fi

if [[ -n "$build_tag" ]]; then ok "ro.oem.build.tag=$build_tag"
else fail "ro.oem.build.tag is empty"; failures=$((failures+1)); fi

# 2. CAs present and byte-identical.
log "checking CAs in /system/etc/security/cacerts/"
for pem in "$CA_DIR"/*.pem; do
    [[ -e "$pem" ]] || continue
    hash=$(openssl x509 -in "$pem" -noout -subject_hash_old)
    hashed="${hash}.0"
    remote="/system/etc/security/cacerts/${hashed}"

    if ! adb shell "[ -f $remote ]" 2>/dev/null; then
        fail "$remote NOT present on device (expected from $(basename "$pem"))"
        failures=$((failures+1))
        continue
    fi

    local_sum=$(sha256sum "$pem" | awk '{print $1}')
    remote_sum=$(adb shell "sha256sum $remote 2>/dev/null" | awk '{print $1}' | tr -d '\r')

    if [[ "$local_sum" == "$remote_sum" ]]; then
        ok "$hashed (sha256=$local_sum) matches $(basename "$pem")"
    else
        fail "$hashed sha256 mismatch: local=$local_sum remote=$remote_sum"
        failures=$((failures+1))
    fi
done

if [[ $failures -eq 0 ]]; then
    log "ALL CHECKS PASSED"
    exit 0
else
    log "$failures CHECK(S) FAILED"
    exit 1
fi
