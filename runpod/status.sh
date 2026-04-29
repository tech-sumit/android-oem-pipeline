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
synced=\$(ls '${SRC_DIR_REMOTE}/.repo/projects' 2>/dev/null | wc -l | tr -d ' ')
total=\$(grep -c '<project ' '${SRC_DIR_REMOTE}/.repo/manifests/default.xml' 2>/dev/null || echo '?')
echo \"  projects synced : \${synced} / \${total}\"
du -sh '${SRC_DIR_REMOTE}' 2>/dev/null | awk '{print \"  source size     : \" \$1}'
du -sh '${SRC_DIR_REMOTE}/out' 2>/dev/null | awk '{print \"  out size        : \" \$1}'
du -sh /workspace/aosp-ccache 2>/dev/null | awk '{print \"  ccache size     : \" \$1}'

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
