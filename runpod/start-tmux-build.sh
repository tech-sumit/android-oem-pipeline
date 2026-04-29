#!/usr/bin/env bash
#
# Start a detached, long-lived MayaOS build on the active RunPod pod.
# The build runs inside tmux so the local SSH session can disconnect without
# stopping repo sync or compilation - exactly the same contract as
# vast/start-tmux-build.sh.
#
# Defaults build both enabled MayaOS variants:
#   - galaxy-s26-ultra-intel-gpu
#   - galaxy-s26-ultra-apple-silicon
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_runpod_auth

REMOTE_DIR="${REMOTE_DIR:-/workspace/android-oem-pipeline}"
SESSION="${TMUX_SESSION:-mayaos-build}"
LOG_DIR="${REMOTE_LOG_DIR:-/workspace/aosp-logs}"
LOG_FILE="${LOG_DIR}/mayaos-build.log"
PROFILES_DEFAULT="galaxy-s26-ultra-intel-gpu,galaxy-s26-ultra-apple-silicon"
PROFILES="${PROFILES:-$PROFILES_DEFAULT}"
REPO_SYNC_JOBS="${REPO_SYNC_JOBS:-1}"
SKIP_SYNC="${SKIP_SYNC:-0}"
# AOSP convention: OUT_DIR is a *relative* path resolved against $PWD (which
# is $SRC_DIR for `m`). Soong's android.validatePathInternal rejects any path
# starting with "/" or "../"; if OUT_DIR is absolute, downstream
# soong_zip / test_package modules emit absolute jar paths
# (e.g. /workspace/aosp-src/out/host/.../foo.jar) that fail validation. Keep
# the build-time value as `out`, but expose the absolute on-disk location for
# mkdir/symlink/rsync calls outside the build.
SRC_DIR_REMOTE="/workspace/aosp-src"
OUT_DIR_RELATIVE="out"
OUT_DIR_ABS="${SRC_DIR_REMOTE}/${OUT_DIR_RELATIVE}"

log "syncing source before tmux build"
"${RUNPOD_DIR}/sync-source.sh"

log "remote: installing tmux and writing build runner"
ssh_into_pod bash -s <<EOS
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq tmux rsync
mkdir -p "${LOG_DIR}" ${SRC_DIR_REMOTE} /workspace/aosp-ccache ${OUT_DIR_ABS} \\
         /workspace/aosp-keys /workspace/aosp-logs /opt/pipeline
# Migrate any legacy sibling OUT_DIR into the in-tree location once.
if [ -d /workspace/aosp-out ] && [ ! -L /workspace/aosp-out ]; then
    rsync -aHAX --remove-source-files /workspace/aosp-out/ ${OUT_DIR_ABS}/ || true
    find /workspace/aosp-out -type d -empty -delete 2>/dev/null || true
    rmdir /workspace/aosp-out 2>/dev/null || true
fi
# Keep the legacy path resolvable for any external scripts (R2 watcher, etc).
ln -sfn ${OUT_DIR_ABS} /workspace/aosp-out
cat > /workspace/run-mayaos-build.sh <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE_DIR="${REMOTE_DIR}"
LOG_DIR="${LOG_DIR}"
LOG_FILE="${LOG_FILE}"
mkdir -p "\$LOG_DIR" ${SRC_DIR_REMOTE} /workspace/aosp-ccache ${OUT_DIR_ABS} \\
         /workspace/aosp-keys /workspace/aosp-logs /opt/pipeline

# Compute a safe -j value. Both nproc and nproc --all return the *host* CPU
# count on RunPod GPU pods (~128 on a shared host) regardless of the cgroup
# CPU quota assigned to our container, and the actual quota is much smaller
# (cpu.max around 16 cores). Worse, memory.max is ~58 GB on a 1xA6000 lease
# while a single Android linker can use 5-15 GB at peak; 128-way parallelism
# would OOM the link phase well before any throttling kicks in.
#
# So: derive -j from cgroup CPU quota and clamp by available RAM.
detect_parallelism() {
    local cpu_quota cpu_period cpu_jobs ram_gb ram_jobs
    if [ -r /sys/fs/cgroup/cpu.max ]; then           # cgroup v2
        read -r cpu_quota cpu_period < /sys/fs/cgroup/cpu.max
        if [ "\$cpu_quota" = "max" ]; then
            cpu_jobs="\$(nproc)"
        else
            cpu_jobs=\$(( (cpu_quota + cpu_period - 1) / cpu_period ))
        fi
    elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then  # cgroup v1
        cpu_quota="\$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)"
        cpu_period="\$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"
        if [ "\$cpu_quota" -le 0 ]; then
            cpu_jobs="\$(nproc)"
        else
            cpu_jobs=\$(( (cpu_quota + cpu_period - 1) / cpu_period ))
        fi
    else
        cpu_jobs="\$(nproc)"
    fi
    [ "\$cpu_jobs" -lt 1 ] && cpu_jobs=1

    # RAM cap: assume ~4 GB/job for AOSP (linker peaks ~10 GB; soong ~2-4 GB).
    if [ -r /sys/fs/cgroup/memory.max ]; then
        ram_gb=\$(( \$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        ram_gb=\$(( \$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes) / 1024 / 1024 / 1024 ))
    else
        ram_gb=\$(free -g | awk '/^Mem:/{print \$2}')
    fi
    [ "\$ram_gb" -lt 1 ] && ram_gb=1
    ram_jobs=\$(( ram_gb / 4 ))
    [ "\$ram_jobs" -lt 1 ] && ram_jobs=1

    if [ "\$cpu_jobs" -lt "\$ram_jobs" ]; then
        echo "\$cpu_jobs"
    else
        echo "\$ram_jobs"
    fi
}

PARALLEL_JOBS="\${PARALLEL_JOBS_OVERRIDE:-\$(detect_parallelism)}"

{
    echo "== MayaOS build started \$(date -u '+%Y-%m-%dT%H:%M:%SZ') =="
    echo "backend=runpod"
    echo "profiles=${PROFILES}"
    echo "repo_sync_jobs=${REPO_SYNC_JOBS}"
    echo "parallel_jobs=\$PARALLEL_JOBS (cgroup-derived)  host_cpu=\$(nproc --all)  nproc=\$(nproc)"
    if [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        echo "cgroup_cpu=\$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)/\$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)us"
    fi
    if [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        echo "cgroup_mem=\$(( \$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes) / 1024 / 1024 / 1024 ))GB"
    fi
    echo "remote_dir=\$REMOTE_DIR"
} | tee -a "\$LOG_FILE"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \\
    bc bison bsdmainutils build-essential ca-certificates ccache cgpt clang \\
    cmake cpio cron curl flex g++-multilib gcc-multilib git git-lfs gnupg \\
    gperf imagemagick jq kmod \\
    lib32ncurses5-dev lib32readline-dev lib32z1-dev liblz4-tool \\
    libelf-dev libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev \\
    libxml2 libxml2-utils lsof lzop \\
    m4 maven nano \\
    openjdk-21-jdk-headless openssl \\
    pigz pkg-config pngcrush procps python3 python3-pip python3-distutils \\
    rsync schedtool squashfs-tools sudo tmux tzdata unzip \\
    wget xdelta3 xsltproc xxd xz-utils \\
    yasm zip zlib1g-dev zstd

if ! command -v yq >/dev/null 2>&1; then
    curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 \\
        -o /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
fi

if ! command -v repo >/dev/null 2>&1; then
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \\
        -o /usr/local/bin/repo
    chmod +x /usr/local/bin/repo
fi

ln -sf /usr/bin/python3 /usr/bin/python
rsync -a --delete "\${REMOTE_DIR}/pipeline/" /opt/pipeline/
chmod +x /opt/pipeline/init.sh /opt/pipeline/hooks/*.sh /opt/pipeline/lib.sh

cd ${SRC_DIR_REMOTE}
env \\
    AOSP_BRANCH='${AOSP_BRANCH:-android-16.0.0_r4}' \\
    PROFILES='${PROFILES}' \\
    SKIP_SYNC='${SKIP_SYNC}' \\
    REPO_SYNC_JOBS='${REPO_SYNC_JOBS}' \\
    PARALLEL_JOBS="\$PARALLEL_JOBS" \\
    USE_CCACHE='1' \\
    CCACHE_MAX_SIZE='${CCACHE_MAX_SIZE:-50G}' \\
    SRC_DIR='${SRC_DIR_REMOTE}' \\
    CCACHE_DIR='/workspace/aosp-ccache' \\
    OUT_DIR='${OUT_DIR_RELATIVE}' \\
    KEYS_DIR='/workspace/aosp-keys' \\
    LOGS_DIR='/workspace/aosp-logs' \\
    LMANIFEST_DIR="\${REMOTE_DIR}/manifests" \\
    DEVICETREE_DIR="\${REMOTE_DIR}/device-tree" \\
    CACERTS_DIR="\${REMOTE_DIR}/ca" \\
    CONFIG_DIR="\${REMOTE_DIR}" \\
    CONFIG_FILE="\${REMOTE_DIR}/mayaos.yaml" \\
    /opt/pipeline/init.sh 2>&1 | tee -a "\$LOG_FILE"
REMOTE
chmod +x /workspace/run-mayaos-build.sh
EOS

log "remote: starting tmux session ${SESSION}"
ssh_into_pod bash -s <<EOS
set -Eeuo pipefail
tmux kill-session -t "${SESSION}" >/dev/null 2>&1 || true
tmux new-session -d -s "${SESSION}" -n build "bash -lc 'bash /workspace/run-mayaos-build.sh; rc=\\\$?; echo; echo \"== MayaOS build process exited with code \\\$rc at \\\$(date -u +%Y-%m-%dT%H:%M:%SZ) ==\"; exec bash'"
tmux set-option -t "${SESSION}" remain-on-exit on >/dev/null
tmux new-window -t "${SESSION}" -n watch "watch -n 30 'date -u; echo === build log ===; tail -60 ${LOG_FILE} 2>/dev/null || true; echo; echo === active repo/build processes ===; ps -eo pid,ppid,stat,pcpu,pmem,etime,comm,args | grep -E \"repo|git|python3|soong|ninja|m -j|run-mayaos|init.sh|tee\" | grep -v grep || true; echo; echo === source size ===; du -sh /workspace/aosp-src /workspace/aosp-src/.repo 2>/dev/null || true; echo; echo === capacity ===; df -h /workspace; free -h'"
tmux ls
EOS

log "tmux build started."
log "watch: ./runpod/tmux-watch.sh"
log "log:   ./runpod/ssh.sh 'tail -f ${LOG_FILE}'"
log "status: ./runpod/status.sh"
