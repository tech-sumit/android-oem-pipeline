#!/usr/bin/env bash
#
# Container entrypoint. Drives the MayaOS Device Farm AOSP build:
#
#   1. Read /srv/config/mayaos.yaml (if present) for defaults.
#   2. Hook before-sync.
#   3. repo init + repo sync against aosp.branch.
#   4. Hook after-sync (default: splice every enabled profile's device tree
#      and CAs into the AOSP source).
#   5. For each enabled profile in mayaos.yaml:
#        a. Hook before-build (default: parity-check spoof block vs .mk).
#        b. lunch ${profile.lunch_target} && m -j${PARALLEL_JOBS}
#        c. Hook after-build (default: package img zip + cvd-host_package
#           into /srv/out/<profile-id>/).
#   6. Hook on-failure on non-zero exit (default: dump tail of build log).
#
# Env vars override config values. Honoured (with config defaults):
#   AOSP_BRANCH         <- aosp.branch         (default android-16.0.0_r4)
#   AOSP_MANIFEST_URL   <- aosp.manifest_url   (default android.googlesource)
#   PARALLEL_JOBS       <- build.parallel_jobs (default $(nproc --all))
#   REPO_SYNC_JOBS      <- repo sync parallelism (default min(PARALLEL_JOBS, 8))
#   CCACHE_MAX_SIZE     <- build.ccache_size   (default 50G)
#   USE_CCACHE          (default 1)
#   SKIP_SYNC           (default 0)
#   SKIP_BUILD          (default 0)
#   PROFILES            (default: every enabled profile in mayaos.yaml,
#                        or LUNCH_TARGET as a one-shot legacy fallback)
#   LUNCH_TARGET        legacy single-profile path; only used if PROFILES is
#                       unset AND no enabled profile exists in the config.
set -Eeuo pipefail

# shellcheck source=lib.sh
source "/opt/pipeline/lib.sh"

trap 'log_error "build failed at line $LINENO (exit $?)"; \
      run_hook on-failure || true; exit 1' ERR

# ---- Resolve config -> env var defaults -----------------------------------
if config_present; then
    log_info "config: ${CONFIG_FILE} (loaded)"
else
    log_warn "config: ${CONFIG_FILE:-/srv/config/mayaos.yaml} not present;" \
             "falling back to env-var-only mode"
fi

AOSP_BRANCH="${AOSP_BRANCH:-$(config_get '.aosp.branch' 'android-16.0.0_r4')}"
AOSP_MANIFEST_URL="${AOSP_MANIFEST_URL:-$(config_get '.aosp.manifest_url' \
    'https://android.googlesource.com/platform/manifest')}"
CCACHE_MAX_SIZE="${CCACHE_MAX_SIZE:-$(config_get '.build.ccache_size' '50G')}"
PARALLEL_JOBS_CFG="$(config_get '.build.parallel_jobs' '')"
[[ -z "${PARALLEL_JOBS:-}" && -n "$PARALLEL_JOBS_CFG" ]] && \
    PARALLEL_JOBS="$PARALLEL_JOBS_CFG"
JOBS="$(resolve_jobs)"
if [[ -n "${REPO_SYNC_JOBS:-}" ]]; then
    SYNC_JOBS="$REPO_SYNC_JOBS"
elif [[ "$JOBS" =~ ^[0-9]+$ && "$JOBS" -gt 8 ]]; then
    SYNC_JOBS=8
else
    SYNC_JOBS="$JOBS"
fi

# ---- Resolve which profiles to build --------------------------------------
# Order of precedence:
#   1. PROFILES env var (space- or comma-separated profile IDs).
#   2. profiles[] entries with enabled: true in mayaos.yaml.
#   3. LUNCH_TARGET env var (single-profile legacy path).
#   4. Hard-coded fallback: mayaos_cf_s26ultra-trunk_staging-userdebug.
declare -a PROFILE_IDS
declare -a LUNCH_TARGETS

if [[ -n "${PROFILES:-}" ]]; then
    IFS=', ' read -r -a PROFILE_IDS <<<"$PROFILES"
    for pid in "${PROFILE_IDS[@]}"; do
        lt="$(profile_get "$pid" '.lunch_target' '')"
        [[ -n "$lt" ]] || { log_error "profile '$pid' has no lunch_target"; exit 1; }
        LUNCH_TARGETS+=("$lt")
    done
elif config_present; then
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        lt="$(profile_get "$pid" '.lunch_target' '')"
        [[ -n "$lt" ]] || { log_error "profile '$pid' has no lunch_target"; exit 1; }
        PROFILE_IDS+=("$pid")
        LUNCH_TARGETS+=("$lt")
    done < <(config_enabled_profile_ids)
fi

if [[ ${#PROFILE_IDS[@]} -eq 0 ]]; then
    legacy_lunch="${LUNCH_TARGET:-mayaos_cf_s26ultra-trunk_staging-userdebug}"
    legacy_id="${legacy_lunch%-*}"
    log_warn "no enabled profiles in config; using legacy single-profile" \
             "path: ${legacy_lunch}"
    PROFILE_IDS=("$legacy_id")
    LUNCH_TARGETS=("$legacy_lunch")
fi

# Export so hooks can introspect.
export PROFILE_IDS_CSV
PROFILE_IDS_CSV=$(IFS=,; echo "${PROFILE_IDS[*]}")

log_phase "MayaOS Device Farm build pipeline"
log_info "AOSP branch       : ${AOSP_BRANCH}"
log_info "Manifest URL      : ${AOSP_MANIFEST_URL}"
log_info "Profiles          : ${PROFILE_IDS_CSV}"
log_info "Parallel jobs     : ${JOBS}"
log_info "Repo sync jobs    : ${SYNC_JOBS}"
log_info "Use ccache        : ${USE_CCACHE:-1}"
log_info "Ccache size       : ${CCACHE_MAX_SIZE}"
log_info "Source dir        : ${SRC_DIR}"
log_info "Output dir        : ${OUT_DIR}"

cd "$SRC_DIR"

# ---- ccache primer ---------------------------------------------------------
if [[ "${USE_CCACHE:-1}" == "1" ]]; then
    ccache -M "${CCACHE_MAX_SIZE}" >/dev/null
    log_info "ccache stats before build:"
    ccache -s | sed 's/^/  /'
fi

# ---- phase 1: before-sync --------------------------------------------------
run_hook before-sync

# ---- phase 2: repo sync ----------------------------------------------------
if [[ "${SKIP_SYNC:-0}" == "1" ]]; then
    log_warn "SKIP_SYNC=1 -- skipping repo init/sync"
else
    log_phase "repo init -b ${AOSP_BRANCH}"
    git config --global user.name  "MayaOS Builder"
    git config --global user.email "build@mayaos.local"
    git config --global color.ui   auto

    if [[ -d "$SRC_DIR/.repo/local_manifests" ]]; then
        rm -f "$SRC_DIR/.repo/local_manifests"/*.xml
    fi

    repo init --depth=1 -u "$AOSP_MANIFEST_URL" -b "$AOSP_BRANCH" --partial-clone
    repo selfupdate || log_warn "repo selfupdate failed (non-fatal)"

    if [[ -d "$LMANIFEST_DIR" ]] && compgen -G "$LMANIFEST_DIR/*.xml" > /dev/null; then
        ensure_dir "$SRC_DIR/.repo/local_manifests"
        cp -v "$LMANIFEST_DIR"/*.xml "$SRC_DIR/.repo/local_manifests/"
    else
        log_info "no local manifests to apply"
    fi

    log_phase "repo sync (${SYNC_JOBS} jobs)"
    repo sync -c --no-tags --no-clone-bundle --optimized-fetch \
        --force-sync --fail-fast -j"${SYNC_JOBS}"
fi

# ---- phase 3: after-sync ---------------------------------------------------
# Splices every enabled profile's device tree and CAs into the AOSP source.
run_hook after-sync

# ---- phase 4-6: per-profile build loop -------------------------------------
if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
    log_warn "SKIP_BUILD=1 -- exiting after sync"
    exit 0
fi

for i in "${!PROFILE_IDS[@]}"; do
    pid="${PROFILE_IDS[$i]}"
    lunch="${LUNCH_TARGETS[$i]}"
    log_phase "profile ${pid} (lunch ${lunch})"

    export CURRENT_PROFILE_ID="$pid"
    export CURRENT_LUNCH_TARGET="$lunch"

    run_hook before-build

    # Build targets per profile:
    #   droid              -- standard "everything in this product" (super.img,
    #                         boot.img, vbmeta, vendor_boot, ...).
    #   cvd-host_package   -- Cuttlefish host runtime archive
    #                         (out/host/linux-x86/cvd-host_package.tar.gz);
    #                         needed by the device farm to boot the bundle in a
    #                         Cuttlefish VM. Bundle is otherwise non-self-contained.
    # MAKE_TARGETS env var overrides the default list.
    pt="${MAKE_TARGETS:-droid cvd-host_package}"
    log_phase "lunch ${lunch} && m -j${JOBS} ${pt}"
    product_out_file="${LOGS_DIR}/product-out-${pid}.txt"
    (
        set +u
        # shellcheck source=/dev/null
        source build/envsetup.sh
        lunch "${lunch}"
        get_build_var PRODUCT_OUT > "${product_out_file}"
        set -u
        # shellcheck disable=SC2086
        m -j"${JOBS}" ${pt} 2>&1 \
            | tee "${LOGS_DIR}/build-${pid}-$(date -u +%Y%m%dT%H%M%SZ).log"
    )

    export CURRENT_PRODUCT_OUT
    CURRENT_PRODUCT_OUT="$(cat "${product_out_file}")"
    run_hook after-build
done

# ---- ccache stats ----------------------------------------------------------
if [[ "${USE_CCACHE:-1}" == "1" ]]; then
    log_info "ccache stats after build:"
    ccache -s | sed 's/^/  /'
fi

log_phase "done (profiles: ${PROFILE_IDS_CSV})"
