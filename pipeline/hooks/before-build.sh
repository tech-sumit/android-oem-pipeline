#!/usr/bin/env bash
#
# Phase 4: between after-sync and `m -j`. Runs once per profile in the loop
# (see init.sh). Reads $CURRENT_PROFILE_ID + $CURRENT_LUNCH_TARGET to know
# what's about to build.
#
# What we check:
#   1. The lunch combo is visible to AOSP's build system.
#   2. The .mk file's PRODUCT_BRAND / PRODUCT_MODEL / PRODUCT_MANUFACTURER /
#      BUILD_FINGERPRINT match mayaos.yaml's profiles[id=$CURRENT].spoof.*.
#      If they drift, fail fast with a clear error -- this is the v1 safety
#      net for the hand-written-.mk approach (vs codegen).
#
set -Eeuo pipefail
# shellcheck source=../lib.sh
source "/opt/pipeline/lib.sh"

PID="${CURRENT_PROFILE_ID:-}"
LUNCH="${CURRENT_LUNCH_TARGET:-}"

if [[ -z "$PID" || -z "$LUNCH" ]]; then
    log_warn "before-build: CURRENT_PROFILE_ID/LUNCH_TARGET unset; skipping" \
             "parity check (legacy single-profile path?)"
    exit 0
fi

log_info "before-build: profile=${PID} lunch=${LUNCH}"

# ---- 1. lunch combo visible? ----------------------------------------------
cd "$SRC_DIR"
(
    set +u
    # shellcheck source=/dev/null
    source build/envsetup.sh
    if ! lunch_choices=$(get_build_var COMMON_LUNCH_CHOICES 2>/dev/null); then
        lunch_choices=""
    fi
    short="${LUNCH%-*}"
    if [[ -n "$lunch_choices" && "$lunch_choices" != *"$short"* ]]; then
        echo "::error::lunch menu does not list ${short}; got: ${lunch_choices}" >&2
        exit 1
    fi
    log_info "  lunch combo '${short}' present"
)

# ---- 2. spoof parity (yaml vs .mk) ----------------------------------------
if ! config_present; then
    log_warn "  no mayaos.yaml -> skipping spoof parity check"
    exit 0
fi

profile_dir="$(profile_get "$PID" '.device_tree' "aosp-tree/device/mayaos/${PID}")"
# `device_tree:` in mayaos.yaml is repo-relative -- aosp-tree/device/mayaos/
# <device>/ -- and gets spliced into $SRC_DIR/device/mayaos/<device>/.
# Strip the aosp-tree/device/ prefix so the rest is relative to
# $SRC_DIR/device/.
case "$profile_dir" in
    aosp-tree/device/*) profile_src_rel="${profile_dir#aosp-tree/device/}" ;;
    *)                  profile_src_rel="$profile_dir" ;;
esac
mk_name="$(profile_get "$PID" '.product_makefile' '')"
if [[ -z "$mk_name" ]]; then
    log_error "profile '${PID}' has no product_makefile in mayaos.yaml"
    exit 1
fi
mk_path="${SRC_DIR}/device/${profile_src_rel}/${mk_name}"

if [[ ! -r "$mk_path" ]]; then
    log_error "expected makefile at ${mk_path} (from mayaos.yaml); not found"
    log_error "  profile_dir from yaml: ${profile_dir}"
    exit 1
fi

# Pull the values from yaml for this profile.
y_brand="$(profile_get "$PID" '.spoof.brand' '')"
y_manuf="$(profile_get "$PID" '.spoof.manufacturer' '')"
y_model="$(profile_get "$PID" '.spoof.model' '')"
y_fingerprint="$(profile_get "$PID" '.spoof.build_fingerprint' '')"

# Pull the values from the .mk(s). Rev 5 split:
#   - per-profile .mk holds inherit-product, PRODUCT_NAME, PRODUCT_DEVICE,
#     ABI list, OEM tag suffix.
#   - vendor/mayaos/product.mk (inherited by every per-profile .mk) holds
#     PRODUCT_BRAND/MODEL/MANUFACTURER and BUILD_FINGERPRINT.
# So search both files and take the first non-empty match.
SHARED_PRODUCT_MK="${SRC_DIR}/vendor/mayaos/product.mk"

extract_mk_var() {
    local var="$1"
    local v
    for f in "$mk_path" "$SHARED_PRODUCT_MK"; do
        [[ -f "$f" ]] || continue
        v="$(awk -v key="$var" '
            $1 == key && $2 == ":=" {
                for (i=3; i<=NF; i++) printf "%s%s", $i, (i==NF?"":" ")
                exit
            }' "$f")"
        if [[ -n "$v" ]]; then
            echo "$v"
            return 0
        fi
    done
    echo ""
}

mk_brand="$(extract_mk_var PRODUCT_BRAND)"
mk_manuf="$(extract_mk_var PRODUCT_MANUFACTURER)"
mk_model="$(extract_mk_var PRODUCT_MODEL)"
mk_fingerprint="$(extract_mk_var BUILD_FINGERPRINT)"

mismatches=0
check_pair() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        log_error "  parity FAIL ${label}:"
        log_error "    yaml:  '${expected}'"
        log_error "    mk:    '${actual}'"
        mismatches=$((mismatches + 1))
    else
        log_info "  parity ok ${label} = '${expected}'"
    fi
}

check_pair "PRODUCT_BRAND"        "$y_brand"       "$mk_brand"
check_pair "PRODUCT_MANUFACTURER" "$y_manuf"       "$mk_manuf"
check_pair "PRODUCT_MODEL"        "$y_model"       "$mk_model"
check_pair "BUILD_FINGERPRINT"    "$y_fingerprint" "$mk_fingerprint"

if [[ "$mismatches" -ne 0 ]]; then
    log_error "before-build: ${mismatches} spoof field(s) drifted between" \
              "mayaos.yaml and ${mk_path}"
    log_error "  fix one or the other and re-run; we refuse to ship a build" \
              "where the .mk and yaml disagree."
    exit 1
fi

log_info "before-build: ok"
