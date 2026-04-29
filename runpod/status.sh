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

echo
log "remote tmux + build snapshot"
ssh_into_pod "
echo '--- tmux ---'
tmux ls 2>/dev/null || echo '(no tmux session)'
echo
echo '--- build processes ---'
ps -eo pid,pcpu,etime,comm,args | grep -E 'soong_ui|ninja|ckati|m -j|init.sh|run-mayaos' | grep -v grep | head -10 || echo '(no build procs)'
echo
echo '--- last 25 log lines ---'
[ -f '${LOG_FILE}' ] && tail -25 '${LOG_FILE}' || echo '(no log file at ${LOG_FILE})'
" || warn "ssh into pod failed (still booting?)"
