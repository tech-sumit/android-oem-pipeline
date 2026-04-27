#!/usr/bin/env bash
#
# Container entrypoint. Drives one full build of the CustomOS AOSP image:
#   1. before-sync hook
#   2. repo init + repo sync (android-16.0.0_r4)
#   3. after-sync hook (default: copies our device tree + CAs into AOSP source)
#   4. before-build hook (default: runs envsetup.sh, lunch)
#   5. m -j$(nproc)
#   6. after-build hook (default: bundles cvd-host_package.tar.gz, copies to /srv/out)
#   7. on-failure hook (only on non-zero exit; default: dumps last 200 lines of build log)
#
# Honoured env vars:
#   AOSP_BRANCH            (default android-16.0.0_r4)
#   AOSP_MANIFEST_URL      (default https://android.googlesource.com/platform/manifest)
#   LUNCH_TARGET           (default customos_cf_x86_64_phone-userdebug)
#   PARALLEL_JOBS          (default $(nproc --all))
#   USE_CCACHE             (default 1)
#   CCACHE_MAX_SIZE        (default 50G)
#   SKIP_SYNC              (default 0; set to 1 to skip repo sync, e.g. for a re-build)
#   SKIP_BUILD             (default 0; set to 1 for sync-only runs)
#
set -Eeuo pipefail

# shellcheck source=lib.sh
source "/opt/pipeline/lib.sh"

trap 'log_error "build failed at line $LINENO (exit $?)"; run_hook on-failure || true; exit 1' ERR

AOSP_BRANCH="${AOSP_BRANCH:-android-16.0.0_r4}"
AOSP_MANIFEST_URL="${AOSP_MANIFEST_URL:-https://android.googlesource.com/platform/manifest}"
LUNCH_TARGET="${LUNCH_TARGET:-customos_cf_x86_64_phone-userdebug}"
JOBS="$(resolve_jobs)"

log_phase "CustomOS build pipeline"
log_info "AOSP branch       : ${AOSP_BRANCH}"
log_info "Manifest URL      : ${AOSP_MANIFEST_URL}"
log_info "Lunch target      : ${LUNCH_TARGET}"
log_info "Parallel jobs     : ${JOBS}"
log_info "Use ccache        : ${USE_CCACHE}"
log_info "Ccache size       : ${CCACHE_MAX_SIZE:-unset}"
log_info "Source dir        : ${SRC_DIR}"
log_info "Output dir        : ${OUT_DIR}"

cd "$SRC_DIR"

# ---- ccache primer ---------------------------------------------------------
if [[ "${USE_CCACHE:-1}" == "1" ]]; then
    ccache -M "${CCACHE_MAX_SIZE:-50G}" >/dev/null
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
    git config --global user.name  "CustomOS Builder"
    git config --global user.email "build@customos.local"
    git config --global color.ui   auto

    repo init --depth=1 -u "$AOSP_MANIFEST_URL" -b "$AOSP_BRANCH" --partial-clone
    repo selfupdate || log_warn "repo selfupdate failed (non-fatal)"

    # Drop in any local manifest fragments (e.g. our customos.xml) before sync
    # so 'repo' picks up our extra projects in a single pass.
    if [[ -d "$LMANIFEST_DIR" ]] && compgen -G "$LMANIFEST_DIR/*.xml" > /dev/null; then
        ensure_dir "$SRC_DIR/.repo/local_manifests"
        cp -v "$LMANIFEST_DIR"/*.xml "$SRC_DIR/.repo/local_manifests/"
    else
        log_info "no local manifests to apply"
    fi

    log_phase "repo sync (${JOBS} jobs)"
    repo sync -c --no-tags --no-clone-bundle --optimized-fetch \
        --force-sync --fail-fast -j"${JOBS}"
fi

# ---- phase 3: after-sync ---------------------------------------------------
# Default: copy our device tree into device/customos and our CAs into the
# product cacerts dir. Override by mounting your own after-sync.sh.
run_hook after-sync

# ---- phase 4: before-build -------------------------------------------------
run_hook before-build

# ---- phase 5: build --------------------------------------------------------
if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
    log_warn "SKIP_BUILD=1 -- exiting after sync"
    exit 0
fi

log_phase "lunch ${LUNCH_TARGET} && m -j${JOBS}"
# build/envsetup.sh requires bash and pollutes the shell, so we source it in
# a subshell to keep init.sh hygiene.
(
    set +u                      # envsetup.sh references unset vars
    # shellcheck source=/dev/null
    source build/envsetup.sh
    lunch "${LUNCH_TARGET}"
    set -u
    m -j"${JOBS}" 2>&1 | tee "${LOGS_DIR}/build-$(date -u +%Y%m%dT%H%M%SZ).log"
)

# ---- phase 6: after-build --------------------------------------------------
run_hook after-build

# ---- ccache stats ----------------------------------------------------------
if [[ "${USE_CCACHE:-1}" == "1" ]]; then
    log_info "ccache stats after build:"
    ccache -s | sed 's/^/  /'
fi

log_phase "done"
