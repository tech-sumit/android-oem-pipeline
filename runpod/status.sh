#!/usr/bin/env bash
#
# Print human-readable status for the active RunPod pod and any in-flight
# build (tmux session + last log lines).
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_runpod_auth

if [[ ! -f "$POD_FILE" ]]; then
    log "no active pod (no ${POD_FILE})"
    log "list everything attached to this account:"
    runpod_get "/pods" | jq -r '.[] | "  \(.id)  \(.name)  status=\(.desiredStatus)  ip=\(.publicIp // "?")  port22=\(.portMappings["22"] // "?")  vcpu=\(.vcpuCount // "?")  ram=\(.memoryInGb // "?")"'
    exit 0
fi

id="$(current_pod_id)"
json="$(runpod_get "/pods/${id}" 2>/dev/null)" || die "pod ${id} not reachable via API"

printf '%s' "$json" | jq -r '
    "pod        : \(.id)",
    "name       : \(.name)",
    "image      : \(.imageName)",
    "status     : \(.desiredStatus)",
    "compute    : \(.computeType // "?")",
    "vcpu       : \(.vcpuCount // "?")",
    "ram(GB)    : \(.memoryInGb // "?")",
    "container  : \(.containerDiskInGb // "?") GB",
    "volume     : \(.volumeInGb // "?") GB at \(.volumeMountPath // "?")",
    "publicIp   : \(.publicIp // "?")",
    "ssh port   : \(.portMappings["22"] // "?")",
    "datacenter : \(.machine.dataCenterId // "?")",
    "uptime     : \(.uptimeSeconds // "?") s"
' || true

LOG_FILE="${RUNPOD_LOG_FILE:-/workspace/aosp-logs/mayaos-build.log}"
SESSION="${TMUX_SESSION:-mayaos-build}"
SRC_DIR_REMOTE="${SRC_DIR_REMOTE:-/workspace/aosp-src}"

echo
log "remote tmux + build snapshot"
# repo sync uses ANSI in-place progress that gets eaten when piped through
# tee, so the build log is silent for the entire sync phase. We compute real
# progress from disk: synced project count vs manifest project count, plus
# bytes on disk and active fetch / build process samples.
ssh_into_pod "
echo '--- tmux ---'
tmux ls 2>/dev/null || echo '(no tmux session)'

echo
echo '--- repo sync progress ---'
# Counting top-level entries in .repo/projects/ undercounts dramatically because
# nested project paths (e.g. external/foo/bar) are stored at depth >1. The real
# signal is: how many of the manifest's <project> paths have a worktree on disk.
synced_total=\$(python3 - <<PY 2>/dev/null
import os, xml.etree.ElementTree as ET
m = '${SRC_DIR_REMOTE}/.repo/manifests/default.xml'
try:
    root = ET.parse(m).getroot()
except Exception:
    print('? / ?'); raise SystemExit
total = 0; present = 0
for p in root.findall('project'):
    total += 1
    path = p.get('path') or p.get('name')
    if os.path.isdir(os.path.join('${SRC_DIR_REMOTE}', path)):
        present += 1
print(f'{present} / {total}')
PY
)
echo \"  projects synced : \${synced_total:-?}\"
du -sh '${SRC_DIR_REMOTE}' 2>/dev/null | awk '{print \"  source size     : \" \$1}'
du -sh '${SRC_DIR_REMOTE}/out' 2>/dev/null | awk '{print \"  out size        : \" \$1}'
du -sh /workspace/aosp-ccache 2>/dev/null | awk '{print \"  ccache size     : \" \$1}'

echo
echo '--- ninja progress ---'
# Soong ninja prints '[ N% built/total]' on every action; the latest is real progress.
grep -oE '^\[ *[0-9]+% +[0-9]+/[0-9]+\]' '${LOG_FILE}' 2>/dev/null | tail -1 | sed 's/^/  /' || echo '  (no ninja progress yet)'

echo
echo '--- cgroup memory (the only real OOM signal) ---'
if [ -r /sys/fs/cgroup/memory/memory.stat ]; then
    awk -v cap=\"\$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)\" '
        /^cache /        { cache=\$2 }
        /^rss /          { rss=\$2 }
        END {
            printf \"  rss (real)      : %.1f GB  ← OOM-killer trigger if this hits the cap\n\", rss/1024/1024/1024
            printf \"  cache           : %.1f GB  ← instantly reclaimable\n\", cache/1024/1024/1024
            printf \"  cap             : %.1f GB\n\", cap/1024/1024/1024
        }
    ' /sys/fs/cgroup/memory/memory.stat
fi
[ -r /sys/fs/cgroup/memory/memory.failcnt ] && \\
    echo \"  failcnt         : \$(cat /sys/fs/cgroup/memory/memory.failcnt) (cache evictions, NOT OOM kills)\"
echo \"  oom kills(dmesg): \$(dmesg 2>/dev/null | grep -ciE 'oom|killed.process' || echo 0)\"

echo
echo '--- active processes ---'
ps -eo pid,pcpu,pmem,etime,comm,args 2>/dev/null \\
    | grep -E 'soong_ui|ninja|ckati|m -j|init.sh|run-mayaos|repo|git fetch|git index-pack|git-remote-https' \\
    | grep -v grep \\
    | head -10 \\
    || echo '(no build procs)'

echo
echo '--- last 15 log lines ---'
[ -f '${LOG_FILE}' ] && tail -15 '${LOG_FILE}' || echo '(no log file at ${LOG_FILE})'

echo
echo '--- capacity ---'
df -h /workspace 2>/dev/null | tail -1
free -h 2>/dev/null | sed -n '1,2p'
" || warn "ssh into pod failed (still booting?)"
