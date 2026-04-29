#!/usr/bin/env bash
#
# Stop billing on the active RunPod pod.
#
# By default we DESTROY the pod (DELETE) so /workspace state and the
# container disk go away. Pass --stop to merely halt it - on RunPod, stopped
# pods retain their /workspace volume but stop billing for compute (you keep
# paying a smaller storage rate).
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_runpod_auth

mode="${1:---destroy}"
id="$(current_pod_id)"

case "$mode" in
    --destroy|-d)
        log "destroying pod ${id} (this is permanent; /workspace volume goes too)"
        runpod_delete "/pods/${id}" >/dev/null
        rm -f "$POD_FILE"
        log "removed ${POD_FILE}"
        ;;
    --stop|-s)
        log "stopping pod ${id} (storage stays, compute stops billing)"
        runpod_post "/pods/${id}/stop" '{}' >/dev/null
        ;;
    --start)
        log "starting pod ${id}"
        runpod_post "/pods/${id}/start" '{}' >/dev/null
        ;;
    *)
        die "usage: $0 [--destroy|--stop|--start]"
        ;;
esac
