#!/usr/bin/env bash
#
# Phase 6: after `m -j` succeeds.
#
# Bundles the artifacts that vast/fetch-artifacts.sh expects, into ${OUT_DIR}:
#   - customos_cf_x86_64_phone-img-<timestamp>.zip   (super.img + boot.img + vbmeta.img + ...)
#   - cvd-host_package.tar.gz                        (Cuttlefish host runtime, from the build)
#   - build-fingerprint.txt                          (ro.build.fingerprint of the produced image)
#   - SHA256SUMS                                     (manifest of the above)
#
set -Eeuo pipefail
# shellcheck source=../lib.sh
source "/opt/pipeline/lib.sh"

PRODUCT_OUT="${SRC_DIR}/out/target/product/vsoc_x86_64"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
ZIP_NAME="customos_cf_x86_64_phone-img-${TS}.zip"

if [[ ! -d "$PRODUCT_OUT" ]]; then
    log_error "expected build output at $PRODUCT_OUT; not found. Did the build actually succeed?"
    exit 1
fi

mkdir -p "$OUT_DIR"

log_phase "after-build: packaging artifacts to ${OUT_DIR}"

# 1. Cuttlefish device image bundle. AOSP produces the inputs but not always a
#    pre-zipped 'img' archive; assemble one from the canonical pieces.
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
    zip -1 "${OUT_DIR}/${ZIP_NAME}" ${img_files[@]}
)
log_info "  wrote ${OUT_DIR}/${ZIP_NAME}"

# 2. cvd-host_package.tar.gz comes out of the build at:
#    out/host/linux-x86/cvd-host_package.tar.gz (modern AOSP)
CVD_PKG="${SRC_DIR}/out/host/linux-x86/cvd-host_package.tar.gz"
if [[ -f "$CVD_PKG" ]]; then
    cp -v "$CVD_PKG" "${OUT_DIR}/cvd-host_package.tar.gz"
else
    log_warn "cvd-host_package.tar.gz not found at $CVD_PKG; using upstream from ci.android.com is recommended"
fi

# 3. Build fingerprint -- proves which CustomOS overlay produced this image.
if FINGERPRINT_RAW=$(grep -m1 '^ro.build.fingerprint=' "${PRODUCT_OUT}/system/build.prop" 2>/dev/null); then
    echo "${FINGERPRINT_RAW#ro.build.fingerprint=}" > "${OUT_DIR}/build-fingerprint.txt"
    log_info "  fingerprint: $(cat "${OUT_DIR}/build-fingerprint.txt")"
fi

# 4. SHA256SUMS manifest.
(
    cd "$OUT_DIR"
    sha256sum -- *.zip *.tar.gz build-fingerprint.txt 2>/dev/null > SHA256SUMS || true
)
log_info "  SHA256SUMS:"
sed 's/^/    /' "${OUT_DIR}/SHA256SUMS"

log_info "after-build: ok"
