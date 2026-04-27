#!/usr/bin/env bash
#
# Build the AOSP-builder Docker image on the remote Vast.ai instance, then
# run it with the right volumes and env vars. Streams logs to your local
# terminal so you can watch the build in real time.
#
# Idempotent: re-running this script reuses the in-instance Docker image and
# the persistent /workspace/aosp-{src,ccache,out,keys,logs} volumes.
#
# Override behavior with env vars:
#   AOSP_BRANCH=android-16.0.0_r4
#   LUNCH_TARGET=customos_cf_x86_64_phone-userdebug
#   PARALLEL_JOBS=  (default: nproc on the instance)
#   SKIP_SYNC=0
#   SKIP_BUILD=0
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_vastai_auth

REMOTE_DIR="${REMOTE_DIR:-/workspace/android-oem-pipeline}"
IMAGE_TAG="${IMAGE_TAG:-customos/aosp-builder:android-16.0.0_r4}"

AOSP_BRANCH="${AOSP_BRANCH:-android-16.0.0_r4}"
LUNCH_TARGET="${LUNCH_TARGET:-customos_cf_x86_64_phone-userdebug}"
SKIP_SYNC="${SKIP_SYNC:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"

log "remote: installing docker if missing"
ssh_into_instance bash -s <<'EOS'
set -Eeuo pipefail
if ! command -v docker >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
fi
docker --version
EOS

log "remote: building image ${IMAGE_TAG}"
ssh_into_instance "cd ${REMOTE_DIR} && docker build \
    --build-arg BUILD_UID=\$(id -u) --build-arg BUILD_GID=\$(id -g) \
    -f docker/Dockerfile -t ${IMAGE_TAG} ."

log "remote: ensuring persistent volumes exist"
ssh_into_instance bash -s <<'EOS'
set -Eeuo pipefail
mkdir -p /workspace/aosp-src /workspace/aosp-ccache /workspace/aosp-out \
         /workspace/aosp-keys /workspace/aosp-logs
EOS

log "remote: kicking build (this takes ~5-7h cold, ~30-60min warm)"
log "  branch: ${AOSP_BRANCH}"
log "  lunch : ${LUNCH_TARGET}"
log "  skip_sync=${SKIP_SYNC} skip_build=${SKIP_BUILD}"

# We use 'script -q -c' to allocate a PTY remotely so coloured AOSP build output
# survives the streaming pipeline. Unbuffered, so logs are real-time.
ssh_into_instance "cd ${REMOTE_DIR} && \
    docker run --rm -t \
        -e AOSP_BRANCH='${AOSP_BRANCH}' \
        -e LUNCH_TARGET='${LUNCH_TARGET}' \
        -e SKIP_SYNC='${SKIP_SYNC}' \
        -e SKIP_BUILD='${SKIP_BUILD}' \
        -e PARALLEL_JOBS='${PARALLEL_JOBS:-}' \
        -v /workspace/aosp-src:/srv/src \
        -v /workspace/aosp-ccache:/srv/ccache \
        -v /workspace/aosp-out:/srv/out \
        -v /workspace/aosp-keys:/srv/keys \
        -v /workspace/aosp-logs:/srv/logs \
        -v ${REMOTE_DIR}/device-tree:/srv/devicetree:ro \
        -v ${REMOTE_DIR}/ca:/srv/cacerts:ro \
        -v ${REMOTE_DIR}/manifests:/srv/local_manifests:ro \
        ${IMAGE_TAG}"

log "build complete. Pull artifacts with: ./vast/fetch-artifacts.sh"
