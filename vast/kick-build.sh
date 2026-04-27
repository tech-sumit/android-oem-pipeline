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

log "remote: installing docker if missing + starting daemon"
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

# Vast.ai instances run inside their own container so systemd is unavailable;
# 'systemctl start docker' is denied by policy-rc.d and the daemon never
# launches. Detect that, then fall back to backgrounded dockerd. We try
# systemctl first because some bare-metal Vast.ai offers DO support it.
if ! docker info >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1 && systemctl start docker 2>/dev/null; then
        :
    elif command -v service >/dev/null 2>&1 && service docker start 2>/dev/null; then
        :
    else
        # Last resort: background dockerd directly. iptables=false because
        # nested containers can't manage iptables; fixed network so containers
        # still get connectivity.
        nohup dockerd \
            --iptables=false \
            --bridge=none \
            --host=unix:///var/run/docker.sock \
            > /var/log/dockerd.log 2>&1 &
        disown
    fi
    # Wait up to 30s for the daemon to be reachable.
    for i in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
fi
docker info >/dev/null 2>&1 || {
    echo "::error::dockerd failed to come up within 30s; tail of /var/log/dockerd.log:" >&2
    tail -n 50 /var/log/dockerd.log 2>&1 || true
    exit 1
}
echo "remote: docker daemon ready"
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
        -e PROFILES='${PROFILES:-}' \
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
        -v ${REMOTE_DIR}/customos.yaml:/srv/config/customos.yaml:ro \
        ${IMAGE_TAG}"

log "build complete. Pull artifacts with: ./vast/fetch-artifacts.sh"
