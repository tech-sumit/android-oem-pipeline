#!/usr/bin/env bash
#
# Phase 6: after `m -j` succeeds for ONE profile.
#
# Bundles artifacts into ${OUT_DIR}/${CURRENT_PROFILE_ID}/:
#   - <profile-id>-img-<timestamp>.zip       (super.img + boot.img + vbmeta + ...)
#   - cvd-host_package.tar.gz                (Cuttlefish host runtime)
#   - build-fingerprint.txt                  (ro.build.fingerprint of this image)
#   - metadata.json                          (machine-readable build manifest)
#   - SHA256SUMS                             (manifest of the above)
#
# If R2_BUCKET / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / R2_ENDPOINT are
# set in env, also publishes the bundle to Cloudflare R2 under a path derived
# from ro.build.fingerprint:
#   s3://${R2_BUCKET}/${R2_PREFIX}/<brand>/<name>/<device>/<release>/<build_id>/<build_incremental>/
# (R2_PREFIX is optional and defaults to empty.)
#
# Multi-profile-aware: each profile gets its own subdir so vast/fetch-artifacts.sh
# and the GH release job can iterate easily.
#
set -Eeuo pipefail
# shellcheck source=../lib.sh
source "/opt/pipeline/lib.sh"

PID="${CURRENT_PROFILE_ID:-mayaos}"
PRODUCT_OUT="${CURRENT_PRODUCT_OUT:-${SRC_DIR}/out/target/product/vsoc_x86_64}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
ZIP_NAME="${PID}-img-${TS}.zip"

# OUT_DIR is intentionally relative ("out") at build time so Soong's path
# validation accepts it. We resolve it to an absolute path here because the
# zip step below cd's into PRODUCT_OUT, which would change what `out/...`
# means relative to the working directory.
if [[ "${OUT_DIR}" = /* ]]; then
    PROFILE_OUT_DIR="${OUT_DIR}/${PID}"
else
    PROFILE_OUT_DIR="${SRC_DIR}/${OUT_DIR}/${PID}"
fi

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

# 2b. AVD-shaped system-image bundle for the Android Studio Emulator.
#
# Cuttlefish lunch targets (aosp_cf_*) emit the standard Cuttlefish artifacts
# only. The Android Studio Emulator (qemu+ranchu) expects a different image
# shape -- kernel-ranchu, system-qemu.img, vendor-qemu.img, ramdisk-qemu.img,
# advancedFeatures.ini -- which the AOSP `sdk_phone64_arm64` (aka emu64a)
# target produces. Many MayaOS profiles co-build both via MAKE_TARGETS so
# the same image can run on either backend.
#
# We package any emulator-shaped files we find in PRODUCT_OUT into
# ${PROFILE_OUT_DIR}/emu/, alongside the SDK metadata files that
# avdmanager / sdkmanager expect. This is the same layout Google ships for
# stock system images (system-images/android-XX/google_apis_playstore/<abi>/)
# and that Genymotion uses for their image catalogue, which means:
#
#   1. `unzip emu/*.zip -C $ANDROID_SDK_ROOT/system-images/android-36.1/...`
#      lights up sdkmanager --list_installed.
#   2. `avdmanager create avd --package "system-images;android-36.1;mayaos;arm64-v8a"`
#      generates a config.ini that the emulator wrapper accepts.
#   3. The emulator wrapper's HVF gate (info.c::_avdInfo_extractBuildProperties
#      reads ro.product.cpu.abi from build.prop) engages on Apple Silicon
#      because we emit the right ABI keys. Without this build.prop the
#      wrapper defaults to "armeabi" and silently falls back to TCG.
#
# Sized by ABI from the lunch target so spoofed name doesn't matter:
#   - lunch contains "arm64" or "_arm64" -> arm64-v8a
#   - lunch contains "x86_64"            -> x86_64
#   - lunch contains "x86"               -> x86
#   - default (cf_*)                     -> arm64-v8a (most common MayaOS variant)
EMU_DIR="${PROFILE_OUT_DIR}/emu"
emu_files=()
for f in kernel-ranchu \
         system-qemu.img system.img \
         vendor-qemu.img vendor.img \
         ramdisk-qemu.img ramdisk.img \
         system_dlkm-qemu.img system_ext-qemu.img \
         userdata.img encryptionkey.img vbmeta.img \
         advancedFeatures.ini kernel_cmdline.txt \
         VerifiedBootParams.textproto; do
    if [[ -f "${PRODUCT_OUT}/${f}" ]]; then
        emu_files+=("${f}")
    fi
done

# kernel-ranchu is the canary -- if there's no ranchu kernel this build doesn't
# include the emulator-shaped flavor and we skip the whole step.
if [[ -f "${PRODUCT_OUT}/kernel-ranchu" ]]; then
    log_info "  packaging emu/ (Android Studio Emulator system-image bundle)"
    rm -rf "$EMU_DIR"
    mkdir -p "$EMU_DIR"
    for f in "${emu_files[@]}"; do
        # Hardlink within the same fs (cheap), copy across fs as fallback.
        if ! ln "${PRODUCT_OUT}/${f}" "${EMU_DIR}/${f}" 2>/dev/null; then
            cp "${PRODUCT_OUT}/${f}" "${EMU_DIR}/${f}"
        fi
    done

    # Derive ABI from CURRENT_LUNCH_TARGET. Cf the AOSP convention:
    #   sdk_phone64_arm64-* / aosp_cf_arm64-* / aosp_arm64-*  -> arm64-v8a
    #   sdk_phone_x86_64-* / aosp_cf_x86_64-*                 -> x86_64
    LUNCH_LOWER="$(echo "${CURRENT_LUNCH_TARGET:-}" | tr '[:upper:]' '[:lower:]')"
    case "$LUNCH_LOWER" in
        *x86_64*) EMU_ABI="x86_64"   ;;
        *arm64*)  EMU_ABI="arm64-v8a" ;;
        *x86*)    EMU_ABI="x86"      ;;
        *)        EMU_ABI="arm64-v8a" ;;
    esac

    # Pin to API 36 / Android 16 -- update this whenever the AOSP_BRANCH bumps
    # (mayaos.yaml's aosp.branch is the source of truth: android-16.0.0_r* -> 36).
    EMU_API_LEVEL="${EMU_API_LEVEL:-36}"
    EMU_API_LEVEL_FULL="${EMU_API_LEVEL_FULL:-36.1}"
    EMU_RELEASE="${EMU_RELEASE:-16}"
    EMU_TAG_ID="mayaos"
    EMU_TAG_DISPLAY="MayaOS"
    EMU_PKG_PATH="system-images;android-${EMU_API_LEVEL_FULL};${EMU_TAG_ID};${EMU_ABI}"

    # build.prop -- gates the emulator wrapper's HVF acceleration on Apple
    # Silicon (via avdInfo_getTargetAbi -> ro.product.cpu.abi). Without this,
    # the wrapper defaults to "armeabi" and the HVF check
    # (main.cpp ~line 2399: strcmp(abi, "arm64-v8a") == 0) fails.
    cat > "${EMU_DIR}/build.prop" <<PROP
####################################
# MayaOS ${EMU_ABI} sysimg metadata for the Android emulator wrapper.
# Source-of-truth keys for avdInfo_getTargetAbi / HVF gate engagement.
# Generated by pipeline/hooks/after-build.sh.
####################################
ro.product.cpu.abi=${EMU_ABI}
ro.product.cpu.abilist=${EMU_ABI}
ro.product.cpu.abilist32=$([ "$EMU_ABI" = "x86" ] && echo "x86" || true)
ro.product.cpu.abilist64=$([ "$EMU_ABI" = "x86" ] && echo "" || echo "${EMU_ABI}")
ro.system.product.cpu.abilist=${EMU_ABI}
ro.system.product.cpu.abilist32=$([ "$EMU_ABI" = "x86" ] && echo "x86" || true)
ro.system.product.cpu.abilist64=$([ "$EMU_ABI" = "x86" ] && echo "" || echo "${EMU_ABI}")
ro.build.version.sdk=${EMU_API_LEVEL}
ro.build.version.sdk_full=${EMU_API_LEVEL_FULL}
ro.build.version.release=${EMU_RELEASE}
ro.system.build.version.sdk=${EMU_API_LEVEL}
ro.system.build.version.sdk_full=${EMU_API_LEVEL_FULL}
ro.product.system.brand=mayaos
ro.product.system.device=${PID}
ro.product.system.manufacturer=MayaOS
ro.product.system.model=MayaOS ${PID}
ro.product.system.name=mayaos_${PID//-/_}
PROP

    # source.properties -- read by sdkmanager --list_installed. Must declare
    # the ABI, API level, and tag/vendor IDs that match package.xml.
    cat > "${EMU_DIR}/source.properties" <<PROP
Pkg.Desc=MayaOS System Image ${EMU_ABI} for ${PID}, built from AOSP ${AOSP_BRANCH:-android-16.0.0}.
Pkg.Revision=1
Pkg.Dependencies=emulator#35.4.9
AndroidVersion.ApiLevel=${EMU_API_LEVEL}
AndroidVersion.IsBaseSdk=true
SystemImage.Abi=${EMU_ABI}
SystemImage.TagId=${EMU_TAG_ID}
SystemImage.TagDisplay=${EMU_TAG_DISPLAY}
SystemImage.GpuSupport=true
Addon.VendorId=mayaos
Addon.VendorDisplay=MayaOS
PROP

    # package.xml -- canonical Repository v2 schema. The `path` attribute is
    # the handle that `avdmanager create avd --package "..."` resolves.
    cat > "${EMU_DIR}/package.xml" <<XML
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02"
                xmlns:ns12="http://schemas.android.com/sdk/android/repo/sys-img2/04">
    <localPackage path="${EMU_PKG_PATH}" obsolete="false">
        <type-details xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="ns12:sysImgDetailsType">
            <api-level>${EMU_API_LEVEL}</api-level>
            <base-extension>true</base-extension>
            <tag>
                <id>${EMU_TAG_ID}</id>
                <display>${EMU_TAG_DISPLAY}</display>
            </tag>
            <vendor>
                <id>mayaos</id>
                <display>MayaOS</display>
            </vendor>
            <abi>${EMU_ABI}</abi>
            <abis>${EMU_ABI}</abis>
        </type-details>
        <revision><major>1</major></revision>
        <display-name>MayaOS ${EMU_ABI} System Image (${PID})</display-name>
        <dependencies>
            <dependency path="emulator">
                <min-revision><major>35</major><minor>4</minor><micro>9</micro></min-revision>
            </dependency>
        </dependencies>
    </localPackage>
</ns2:repository>
XML

    log_info "    abi=${EMU_ABI} api=${EMU_API_LEVEL_FULL} pkg=${EMU_PKG_PATH}"
    log_info "    files: $(ls "$EMU_DIR" | tr '\n' ' ')"
else
    log_info "  no kernel-ranchu in $PRODUCT_OUT; skipping emu/ bundle" \
             "(this profile didn't co-build a sdk_phone64_* target)"
fi

# 3. Build fingerprint -- proves which MayaOS overlay produced this image.
#    Prefer vendor/build.prop because our spoof overrides land there via
#    PRODUCT_PROPERTY_OVERRIDES + BUILD_BROKEN_DUP_SYSPROP. Android init's
#    last-write-wins behavior at runtime resolves to the vendor value, so
#    this is what a device actually reports.
FINGERPRINT_RAW=""
for PROP_FILE in "${PRODUCT_OUT}/vendor/build.prop" \
                  "${PRODUCT_OUT}/system/build.prop"; do
    if [[ -f "$PROP_FILE" ]]; then
        FINGERPRINT_RAW="$(grep -m1 '^ro.build.fingerprint=' "$PROP_FILE" 2>/dev/null || true)"
        [[ -n "$FINGERPRINT_RAW" ]] && break
    fi
done
if [[ -n "$FINGERPRINT_RAW" ]]; then
    echo "${FINGERPRINT_RAW#ro.build.fingerprint=}" \
        > "${PROFILE_OUT_DIR}/build-fingerprint.txt"
    log_info "  fingerprint: $(cat "${PROFILE_OUT_DIR}/build-fingerprint.txt")"
else
    log_warn "  no ro.build.fingerprint found in vendor/ or system/ build.prop"
fi

# 4. Profile metadata. Useful for the GH Release table and R2 layout.
{
    echo "profile_id=${PID}"
    echo "lunch_target=${CURRENT_LUNCH_TARGET:-}"
    echo "image_zip=${ZIP_NAME}"
    echo "build_timestamp=${TS}"
} > "${PROFILE_OUT_DIR}/profile.txt"

# 5. metadata.json -- single source of truth for downstream consumers
#    (release notes, R2 watcher, the device-farm dispatcher). Captures the
#    full fingerprint decomposed into S3-key components, the spoof block,
#    git provenance, and the artifact's size + sha256.
ZIP_PATH="${PROFILE_OUT_DIR}/${ZIP_NAME}"
ZIP_SIZE="$(stat -c%s "$ZIP_PATH" 2>/dev/null || echo 0)"
ZIP_SHA="$(sha256sum "$ZIP_PATH" 2>/dev/null | cut -d' ' -f1)"
FP="$(cat "${PROFILE_OUT_DIR}/build-fingerprint.txt" 2>/dev/null || echo "")"
ISO_TS="$(date -u -d "${TS:0:4}-${TS:4:2}-${TS:6:2}T${TS:9:2}:${TS:11:2}:${TS:13:2}Z" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

# Decompose fingerprint:  brand/name/device:release/build_id/build_incremental:type/tags
fp_brand="$(echo "$FP" | cut -d/ -f1)"
fp_name="$(echo "$FP" | cut -d/ -f2)"
fp_device="$(echo "$FP" | cut -d/ -f3 | cut -d: -f1)"
fp_release="$(echo "$FP" | cut -d/ -f3 | cut -d: -f2)"
fp_buildid="$(echo "$FP" | cut -d/ -f4)"
fp_buildincr="$(echo "$FP" | cut -d/ -f5 | cut -d: -f1)"
fp_buildtype="$(echo "$FP" | cut -d/ -f5 | cut -d: -f2)"
fp_tags="$(echo "$FP" | cut -d/ -f6)"

GIT_SHA_VAL=""
GIT_BRANCH_VAL=""
GIT_REMOTE_VAL=""
if [[ -n "${PIPELINE_GIT_SHA:-}" ]]; then
    GIT_SHA_VAL="$PIPELINE_GIT_SHA"
    GIT_BRANCH_VAL="${PIPELINE_GIT_BRANCH:-}"
    GIT_REMOTE_VAL="${PIPELINE_GIT_REMOTE:-}"
fi

cat > "${PROFILE_OUT_DIR}/metadata.json" <<JSON
{
  "schema_version": 1,
  "build": {
    "profile_id": "${PID}",
    "lunch_target": "${CURRENT_LUNCH_TARGET:-}",
    "timestamp_utc": "${ISO_TS}",
    "backend": "${BUILD_BACKEND:-runpod}",
    "aosp_branch": "${AOSP_BRANCH:-}"
  },
  "fingerprint": {
    "raw": "${FP}",
    "brand": "${fp_brand}",
    "product_name": "${fp_name}",
    "device": "${fp_device}",
    "release": "${fp_release}",
    "build_id": "${fp_buildid}",
    "build_incremental": "${fp_buildincr}",
    "build_type": "${fp_buildtype}",
    "tags": "${fp_tags}"
  },
  "git": {
    "commit_sha": "${GIT_SHA_VAL}",
    "branch": "${GIT_BRANCH_VAL}",
    "remote": "${GIT_REMOTE_VAL}"
  },
  "artifact": {
    "name": "${ZIP_NAME}",
    "size_bytes": ${ZIP_SIZE},
    "sha256": "${ZIP_SHA}"
  }
}
JSON
log_info "  wrote ${PROFILE_OUT_DIR}/metadata.json"

# 6. SHA256SUMS manifest. Includes the emu/ subdir so consumers can verify
# system-image bytes match what the build emitted (catches mid-flight bitrot
# during R2 transfers, etc).
(
    cd "$PROFILE_OUT_DIR"
    {
        sha256sum -- *.zip *.tar.gz build-fingerprint.txt profile.txt metadata.json 2>/dev/null
        if [[ -d emu ]]; then
            find emu -type f -print0 | sort -z | xargs -0 sha256sum
        fi
    } > SHA256SUMS || true
)
log_info "  SHA256SUMS:"
sed 's/^/    /' "${PROFILE_OUT_DIR}/SHA256SUMS"

# 7. Cloudflare R2 publish. Opt-in: only runs if the four R2 env vars are
#    present. Path encodes ro.build.fingerprint so consumers can address an
#    image by its identity (e.g. samsung/s26uxxx/s26u/16/<id>/<incr>/...).
#    No-op (with a single-line warn) if creds are absent so local-only builds
#    keep working unchanged.
publish_to_r2() {
    : "${R2_BUCKET:?missing}" \
      "${R2_ENDPOINT:?missing}" \
      "${AWS_ACCESS_KEY_ID:?missing}" \
      "${AWS_SECRET_ACCESS_KEY:?missing}" \
      "${fp_brand:?missing}" "${fp_name:?missing}" "${fp_device:?missing}" \
      "${fp_release:?missing}" "${fp_buildid:?missing}" "${fp_buildincr:?missing}"

    if ! command -v aws >/dev/null 2>&1; then
        log_warn "  aws cli missing; installing..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq awscli >/dev/null
    fi

    local prefix="${R2_PREFIX:-}"
    [[ -n "$prefix" ]] && prefix="${prefix%/}/"
    # Append PID so multiple profiles with the same spoofed fingerprint
    # (e.g. galaxy-s26-ultra-intel-gpu and galaxy-s26-ultra-apple-silicon both
    # spoof the same Samsung phone but differ in CPU arch / runtime container)
    # don't clobber each other's bundles in R2.
    local s3_path="${prefix}${fp_brand}/${fp_name}/${fp_device}/${fp_release}/${fp_buildid}/${fp_buildincr}/${PID}"
    local s3_dest="s3://${R2_BUCKET}/${s3_path}"
    local AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
    export AWS_DEFAULT_REGION

    log_phase "after-build: publishing to ${s3_dest}/"
    local f
    for f in "${ZIP_NAME}" "metadata.json" "SHA256SUMS" "profile.txt" "build-fingerprint.txt"; do
        [[ -f "${PROFILE_OUT_DIR}/${f}" ]] || continue
        local ct="application/octet-stream"
        case "$f" in
            *.json) ct="application/json" ;;
            *.txt|SHA256SUMS|build-fingerprint.txt) ct="text/plain" ;;
        esac
        aws s3 --endpoint-url="$R2_ENDPOINT" cp \
            "${PROFILE_OUT_DIR}/${f}" "${s3_dest}/${f}" \
            --content-type "$ct" --no-progress
        log_info "  uploaded ${f}"
    done

    # cvd-host_package.tar.gz is large; copy by reference so it lives in
    # PROFILE_OUT_DIR for sha256+local fetch and ALSO at the R2 path.
    if [[ -f "${PROFILE_OUT_DIR}/cvd-host_package.tar.gz" ]]; then
        aws s3 --endpoint-url="$R2_ENDPOINT" cp \
            "${PROFILE_OUT_DIR}/cvd-host_package.tar.gz" \
            "${s3_dest}/cvd-host_package.tar.gz" --no-progress
        log_info "  uploaded cvd-host_package.tar.gz"
    fi

    # Sync the entire emu/ system-image bundle so a Mac client can do
    # `aws s3 sync s3://.../emu/ $ANDROID_SDK_ROOT/system-images/android-36.1/mayaos/arm64-v8a/`
    # and immediately have a working AVD package.
    if [[ -d "${PROFILE_OUT_DIR}/emu" ]]; then
        aws s3 --endpoint-url="$R2_ENDPOINT" sync \
            "${PROFILE_OUT_DIR}/emu/" "${s3_dest}/emu/" --no-progress
        log_info "  uploaded emu/ ($(ls "${PROFILE_OUT_DIR}/emu" | wc -l | tr -d ' ') files)"
    fi

    log_info "  R2 path: ${s3_dest}/"
}

if [[ -n "${R2_BUCKET:-}" && -n "${R2_ENDPOINT:-}" \
      && -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    publish_to_r2 || log_warn "R2 publish failed; bundle still on local disk"
else
    log_warn "  R2_* env vars not set; skipping R2 publish (local-only build)"
fi

log_info "after-build: ok"
