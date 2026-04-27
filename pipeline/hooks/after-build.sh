#!/usr/bin/env bash
#
# Phase 6: after `m -j` succeeds for ONE profile.
#
# Bundles artifacts into ${OUT_DIR}/${CURRENT_PROFILE_ID}/:
#   - <profile-id>-img-<timestamp>.zip       (super.img + boot.img + vbmeta + ...)
#   - cvd-host_package.tar.gz                (Cuttlefish host runtime)
#   - build-fingerprint.txt                  (ro.build.fingerprint of this image)
#   - SHA256SUMS                             (manifest of the above)
#
# Multi-profile-aware: each profile gets its own subdir so vast/fetch-artifacts.sh
# and the GH release job can iterate easily.
#
set -Eeuo pipefail
# shellcheck source=../lib.sh
source "/opt/pipeline/lib.sh"

PID="${CURRENT_PROFILE_ID:-customos}"
PRODUCT_OUT="${SRC_DIR}/out/target/product/vsoc_x86_64"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
ZIP_NAME="${PID}-img-${TS}.zip"
PROFILE_OUT_DIR="${OUT_DIR}/${PID}"

if [[ ! -d "$PRODUCT_OUT" ]]; then
    log_error "expected build output at $PRODUCT_OUT; not found." \
              "Did the build actually succeed?"
    exit 1
fi

mkdir -p "$PROFILE_OUT_DIR"

log_phase "after-build: packaging artifacts for ${PID} -> ${PROFILE_OUT_DIR}"

# 1. Cuttlefish device image bundle.
img_files=()
for f in super.img boot.img vbmeta.img vendor_boot.img init_boot.img \
         android-info.txt misc_info.txt; do
    if [[ -f "${PRODUCT_OUT}/${f}" ]]; then
        img_files+=("${f}")
    fi
done

if [[ ${#img_files[@]} -eq 0 ]]; then
    log_error "no image files found in $PRODUCT_OUT; build output looks incomplete"
    exit 1
fi

(
    cd "$PRODUCT_OUT"
    # shellcheck disable=SC2068
    zip -1 "${PROFILE_OUT_DIR}/${ZIP_NAME}" ${img_files[@]}
)
log_info "  wrote ${PROFILE_OUT_DIR}/${ZIP_NAME}"

# 2. cvd-host_package.tar.gz from the build's host output.
CVD_PKG="${SRC_DIR}/out/host/linux-x86/cvd-host_package.tar.gz"
if [[ -f "$CVD_PKG" ]]; then
    cp "$CVD_PKG" "${PROFILE_OUT_DIR}/cvd-host_package.tar.gz"
    log_info "  wrote ${PROFILE_OUT_DIR}/cvd-host_package.tar.gz"
else
    log_warn "cvd-host_package.tar.gz not found at $CVD_PKG; the device farm" \
             "consumer can fall back to the upstream from ci.android.com"
fi

# 3. Build fingerprint -- proves which CustomOS overlay produced this image.
if FINGERPRINT_RAW=$(grep -m1 '^ro.build.fingerprint=' \
        "${PRODUCT_OUT}/system/build.prop" 2>/dev/null); then
    echo "${FINGERPRINT_RAW#ro.build.fingerprint=}" \
        > "${PROFILE_OUT_DIR}/build-fingerprint.txt"
    log_info "  fingerprint: $(cat "${PROFILE_OUT_DIR}/build-fingerprint.txt")"
fi

# 4. Profile metadata. Useful for the GH Release table and R2 layout.
{
    echo "profile_id=${PID}"
    echo "lunch_target=${CURRENT_LUNCH_TARGET:-}"
    echo "image_zip=${ZIP_NAME}"
    echo "build_timestamp=${TS}"
} > "${PROFILE_OUT_DIR}/profile.txt"

# 5. SHA256SUMS manifest.
(
    cd "$PROFILE_OUT_DIR"
    sha256sum -- *.zip *.tar.gz build-fingerprint.txt profile.txt 2>/dev/null \
        > SHA256SUMS || true
)
log_info "  SHA256SUMS:"
sed 's/^/    /' "${PROFILE_OUT_DIR}/SHA256SUMS"

log_info "after-build: ok"
