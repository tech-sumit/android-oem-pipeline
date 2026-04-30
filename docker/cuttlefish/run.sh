#!/usr/bin/env bash
#
# Boot a built MayaOS profile inside a Cuttlefish container on this host.
# Designed for macOS arm64 (M-series), where the only available path is the
# upstream cuttlefish-orchestration image and our linux-x86_64 host package
# (running under Rosetta + TCG, no /dev/kvm). On a real Linux host with
# /dev/kvm exposed, we'd be much faster -- the script auto-detects.
#
# Inputs (env, all optional unless noted):
#   PROFILE              -- profile bundle directory name in BUNDLE_ROOT,
#                           e.g. galaxy-s26-ultra-apple-silicon (REQUIRED).
#   BUNDLE_ROOT          -- path containing <PROFILE>/super.img etc.
#                           Defaults to <repo>/out/latest.
#   CONTAINER_NAME       -- defaults to cf-mayaos.
#   CVD_IMAGE            -- container image to use.
#   PLATFORM             -- linux/amd64 (default; matches our x86_64 host pkg)
#                           or linux/arm64 (only if you have an arm64 hosttar).
#   ADB_PORT             -- host port mapped to container's 6520. Default 6520.
#   OPERATOR_PORT        -- host port mapped to container's 1080 (orchestrator
#                           HTTP UI). Default 1080.
#   OPERATOR_HTTPS_PORT  -- host port mapped to container's 1443. Default 1443.
#   WEBRTC_PORT          -- host port mapped to container's 2080 (WebRTC live
#                           stream operator endpoint). Default 2080.
#   CVD_CPUS / CVD_MEMORY_MB -- guest sizing; defaults are conservative for Mac.
#   START_TIMEOUT_S      -- seconds to wait for `cvd create` to return. Default
#                           3600 (60 min) because triple emulation is slow.
#
# After the container starts, the entrypoint orchestrator listens, and we exec
# `cvd create` inside it to spin up an instance. Use:
#
#   docker logs -f <CONTAINER_NAME>     # cuttlefish bring-up logs
#   docker exec -it <CONTAINER_NAME> bash
#   adb connect 127.0.0.1:<ADB_PORT>    # then `adb shell` or `scrcpy`
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

log()  { printf '\033[1;34m[cf-run]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[cf-run][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[cf-run][err]\033[0m %s\n' "$*" >&2; exit 1; }

: "${PROFILE:?missing env: PROFILE (e.g. galaxy-s26-ultra-apple-silicon)}"

BUNDLE_ROOT="${BUNDLE_ROOT:-${REPO_ROOT}/out/latest}"
PROFILE_DIR="${BUNDLE_ROOT}/${PROFILE}"
[[ -d "$PROFILE_DIR" ]] || die "profile bundle not found: ${PROFILE_DIR}; run 'make r2-fetch-latest PROFILES=${PROFILE}' first"

CONTAINER_NAME="${CONTAINER_NAME:-cf-mayaos}"
CVD_IMAGE="${CVD_IMAGE:-us-docker.pkg.dev/android-cuttlefish-artifacts/cuttlefish-orchestration/cuttlefish-orchestration:stable}"
PLATFORM="${PLATFORM:-linux/amd64}"
ADB_PORT="${ADB_PORT:-6520}"
OPERATOR_PORT="${OPERATOR_PORT:-1080}"
OPERATOR_HTTPS_PORT="${OPERATOR_HTTPS_PORT:-1443}"
WEBRTC_PORT="${WEBRTC_PORT:-2080}"
CVD_CPUS="${CVD_CPUS:-4}"
CVD_MEMORY_MB="${CVD_MEMORY_MB:-4096}"
START_TIMEOUT_S="${START_TIMEOUT_S:-3600}"

# --- 1. Stage the profile contents into a docker-friendly layout. ----------
# Cuttlefish's `cvd create --product_path=...` wants a directory full of
# *unpacked* image files (super.img, boot.img, vbmeta.img, vendor_boot.img,
# init_boot.img). It also wants `--host_path=...` pointing at the unpacked
# cvd-host_package contents (i.e. ./bin, ./etc, ./usr/, ./lib64).
IMAGES_DIR="${PROFILE_DIR}/images"
HOST_DIR="${PROFILE_DIR}/host"

if [[ ! -f "${IMAGES_DIR}/super.img" ]]; then
    log "extracting img zip into ${IMAGES_DIR}"
    mkdir -p "$IMAGES_DIR"
    img_zip="$(ls "${PROFILE_DIR}"/*-img-*.zip | head -1)"
    [[ -n "$img_zip" ]] || die "no img zip in ${PROFILE_DIR}"
    unzip -o -q "$img_zip" -d "$IMAGES_DIR"
fi

if [[ ! -d "${HOST_DIR}/bin" ]]; then
    log "extracting cvd-host_package into ${HOST_DIR}"
    mkdir -p "$HOST_DIR"
    [[ -f "${PROFILE_DIR}/cvd-host_package.tar.gz" ]] \
        || die "missing ${PROFILE_DIR}/cvd-host_package.tar.gz"
    tar -xzf "${PROFILE_DIR}/cvd-host_package.tar.gz" -C "$HOST_DIR"
fi

# --- 2. Tear down any stale container with the same name. ------------------
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    log "removing stale container ${CONTAINER_NAME}"
    docker rm -f "$CONTAINER_NAME" >/dev/null
fi

# --- 3. Detect /dev/kvm availability. --------------------------------------
# Macs never have it, Linux Docker hosts usually do. Without /dev/kvm,
# crosvm/qemu fall back to TCG which is ~20-40x slower for Android boot.
KVM_OPTS=()
if [[ -e /dev/kvm ]]; then
    log "/dev/kvm present on host -- enabling KVM passthrough"
    KVM_OPTS=(--device /dev/kvm)
else
    warn "/dev/kvm NOT present (you're likely on macOS or Docker Desktop)."
    warn "Cuttlefish will fall back to software emulation (TCG). Boot will"
    warn "be slow (30-60 min) and the UI will lag, but it WILL boot."
fi

# --- 4. Launch the orchestration container. --------------------------------
log "starting container ${CONTAINER_NAME} (${PLATFORM})"
log "  image=${CVD_IMAGE}"
log "  profile=${PROFILE}"
log "  product_path=${IMAGES_DIR}  ->  /cvd/images"
log "  host_path=${HOST_DIR}        ->  /cvd/host"
log "  ports: adb 127.0.0.1:${ADB_PORT}->6520, operator 127.0.0.1:${OPERATOR_PORT}->1080,"
log "         operator-https 127.0.0.1:${OPERATOR_HTTPS_PORT}->1443, webrtc 127.0.0.1:${WEBRTC_PORT}->2080"

docker run -d \
    --name "$CONTAINER_NAME" \
    --platform "$PLATFORM" \
    --privileged \
    ${KVM_OPTS[@]+"${KVM_OPTS[@]}"} \
    -p "127.0.0.1:${ADB_PORT}:6520" \
    -p "127.0.0.1:${OPERATOR_PORT}:1080" \
    -p "127.0.0.1:${OPERATOR_HTTPS_PORT}:1443" \
    -p "127.0.0.1:${WEBRTC_PORT}:2080" \
    -v "${IMAGES_DIR}:/cvd/images" \
    -v "${HOST_DIR}:/cvd/host" \
    "$CVD_IMAGE" \
    >/dev/null

# --- 5. Wait for `cvd` to be usable inside the container. ------------------
# Cuttlefish bring-up runs `run_services.sh` which sets up nginx, networking,
# and the orchestrator (port 2081). The orchestrator's HTTP routes (`/v1/...`)
# only respond to specific endpoints and 404 on unknown URLs, so probing
# `/v1/info` isn't reliable. Instead, verify the cvd CLI itself is responsive.
log "waiting for cuttlefish init to finish (max 60s)..."
for i in $(seq 1 60); do
    if docker exec "$CONTAINER_NAME" cvd version >/dev/null 2>&1; then
        log "cvd is responsive after ${i}s"
        break
    fi
    [[ $i -eq 60 ]] && die "cvd never came up; check 'docker logs ${CONTAINER_NAME}'"
    sleep 1
done

# --- 6. Kick off `cvd create`. ----------------------------------------------
# We run this OUTSIDE of `docker run -d` so logs stream live. Cuttlefish does
# NOT background by default, but with --start the boot is launched and `cvd`
# returns once it's reported boot completion (or hit START_TIMEOUT_S).
log "issuing 'cvd create' inside the container (this is the slow part)..."
log "  --cpus=${CVD_CPUS} --memory_mb=${CVD_MEMORY_MB}"
log "  follow boot progress with:  docker logs -f ${CONTAINER_NAME}"
log "  or:                          docker exec -it ${CONTAINER_NAME} bash"
echo

# Background the cvd start so the script returns control quickly. The launch
# logs live in the container's stdout (visible via docker logs).
docker exec -d "$CONTAINER_NAME" bash -lc "
    cd /cvd/host
    cvd create \
        --host_path=/cvd/host \
        --product_path=/cvd/images \
        --cpus=${CVD_CPUS} \
        --memory_mb=${CVD_MEMORY_MB} \
        > /tmp/cvd-create.log 2>&1
"

log "cvd create launched in background inside the container."
log
log "Next steps:"
log "  1. Watch boot progress:"
log "       docker exec -it ${CONTAINER_NAME} tail -f /tmp/cvd-create.log"
log "       docker exec -it ${CONTAINER_NAME} tail -f /home/vsoc-01/cuttlefish_runtime/launcher.log 2>/dev/null"
log "  2. Once 'VIRTUAL_DEVICE_BOOT_COMPLETED' shows up (~30-60 min on Mac),"
log "     connect adb and launch scrcpy:"
log "       adb connect 127.0.0.1:${ADB_PORT}"
log "       scrcpy -s 127.0.0.1:${ADB_PORT}"
log "  3. Stop with:  make cuttlefish-down"
