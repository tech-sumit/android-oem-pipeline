#!/usr/bin/env bash
#
# Run the AOSP build directly inside the rented Vast.ai container.
#
# Vast.ai SSH instances are already containers. Some offers do not permit
# nested Docker/BuildKit mounts, so this path installs the same toolchain as
# docker/Dockerfile into the active container and then runs pipeline/init.sh.
#
# Override behavior with env vars:
#   PROFILES=galaxy-s26-ultra
#   PARALLEL_JOBS=28
#   REPO_SYNC_JOBS=8
#   SKIP_SYNC=0
#   SKIP_BUILD=0
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_vastai_auth

REMOTE_DIR="${REMOTE_DIR:-/workspace/android-oem-pipeline}"
AOSP_BRANCH="${AOSP_BRANCH:-android-16.0.0_r4}"
SKIP_SYNC="${SKIP_SYNC:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"

log "remote: installing direct-build toolchain"
ssh_into_instance bash -s <<'EOS'
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    bc bison bsdmainutils build-essential ca-certificates ccache cgpt clang \
    cmake cpio cron curl flex g++-multilib gcc-multilib git git-lfs gnupg \
    gperf imagemagick jq kmod \
    lib32ncurses5-dev lib32readline-dev lib32z1-dev liblz4-tool \
    libelf-dev libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev \
    libxml2 libxml2-utils lsof lzop \
    m4 maven nano \
    openjdk-21-jdk-headless openssl \
    pigz pkg-config pngcrush procps python3 python3-pip python3-distutils \
    rsync schedtool squashfs-tools sudo tzdata unzip \
    wget xdelta3 xsltproc xxd xz-utils \
    yasm zip zlib1g-dev zstd

if ! command -v yq >/dev/null 2>&1; then
    curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 \
        -o /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
fi

if ! command -v repo >/dev/null 2>&1; then
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
        -o /usr/local/bin/repo
    chmod +x /usr/local/bin/repo
fi

ln -sf /usr/bin/python3 /usr/bin/python
yq --version
repo version || true
EOS

log "remote: preparing persistent workspace"
ssh_into_instance bash -s <<EOS
set -Eeuo pipefail

mkdir -p /workspace/aosp-src /workspace/aosp-ccache /workspace/aosp-out \\
         /workspace/aosp-keys /workspace/aosp-logs /opt/pipeline
rsync -a --delete "${REMOTE_DIR}/pipeline/" /opt/pipeline/
chmod +x /opt/pipeline/init.sh /opt/pipeline/hooks/*.sh /opt/pipeline/lib.sh

echo "nproc=\$(nproc --all)"
df -h /workspace || true
free -h || true
EOS

PARALLEL_JOBS_REMOTE="${PARALLEL_JOBS:-}"

log "remote: kicking direct build inside Vast container"
log "  branch: ${AOSP_BRANCH}"
log "  profiles: ${PROFILES:-enabled profiles from mayaos.yaml}"
log "  parallel jobs: ${PARALLEL_JOBS:-all allocated CPUs on the instance}"
log "  repo sync jobs: ${REPO_SYNC_JOBS:-pipeline default}"
log "  skip_sync=${SKIP_SYNC} skip_build=${SKIP_BUILD}"

ssh_into_instance "cd /workspace/aosp-src && \
    PARALLEL_JOBS_VALUE='${PARALLEL_JOBS_REMOTE}' && \
    if [ -z \"\${PARALLEL_JOBS_VALUE}\" ]; then PARALLEL_JOBS_VALUE=\$(nproc --all); fi && \
    env \
        AOSP_BRANCH='${AOSP_BRANCH}' \
        PROFILES='${PROFILES:-}' \
        SKIP_SYNC='${SKIP_SYNC}' \
        SKIP_BUILD='${SKIP_BUILD}' \
        PARALLEL_JOBS=\"\${PARALLEL_JOBS_VALUE}\" \
        REPO_SYNC_JOBS='${REPO_SYNC_JOBS:-}' \
        USE_CCACHE='1' \
        CCACHE_MAX_SIZE='${CCACHE_MAX_SIZE:-50G}' \
        SRC_DIR='/workspace/aosp-src' \
        CCACHE_DIR='/workspace/aosp-ccache' \
        OUT_DIR='/workspace/aosp-out' \
        KEYS_DIR='/workspace/aosp-keys' \
        LOGS_DIR='/workspace/aosp-logs' \
        LMANIFEST_DIR='${REMOTE_DIR}/manifests' \
        DEVICETREE_DIR='${REMOTE_DIR}/device-tree' \
        CACERTS_DIR='${REMOTE_DIR}/ca' \
        CONFIG_DIR='${REMOTE_DIR}' \
        CONFIG_FILE='${REMOTE_DIR}/mayaos.yaml' \
        /opt/pipeline/init.sh"

log "build complete. Pull artifacts with: ./vast/fetch-artifacts.sh"
