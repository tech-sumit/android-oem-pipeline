#!/usr/bin/env bash
#
# Attach to the remote MayaOS tmux build session running on the active
# RunPod pod.
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SESSION="${TMUX_SESSION:-mayaos-build}"
ensure_runpod_auth

IFS=$'\t' read -r user host port < <(current_pod_ssh)
key="$(ssh_key_path)"
[[ -f "$key" ]] || die "ssh key not found: $key (ssh-keygen -t ed25519 -f $key)"

ssh -tt -i "$key" -p "$port" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=120 \
    "${user}@${host}" "tmux attach -t '${SESSION}'"
