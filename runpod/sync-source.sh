#!/usr/bin/env bash
#
# rsync this repository (Dockerfile + pipeline + device-tree + ca + manifests)
# to the active RunPod pod under /workspace/android-oem-pipeline.
#
# Excludes mirror runpod/sync-source.sh's vast/ counterpart -- both backends
# run the same pipeline/ code path and only differ in lifecycle scripts.
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_runpod_auth
require rsync

SSH_KEY="$(ssh_key_path)"
IFS=$'\t' read -r user host port < <(current_pod_ssh)

REMOTE_DIR="${REMOTE_DIR:-/workspace/android-oem-pipeline}"

log "rsync ${REPO_ROOT} -> ${user}@${host}:${REMOTE_DIR}"

ssh_into_pod "mkdir -p ${REMOTE_DIR}"

rsync -azP --delete \
    -e "ssh -i ${SSH_KEY} -p ${port} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
    --exclude '.git/' \
    --exclude 'vast/' \
    --exclude 'runpod/' \
    --exclude 'out/' \
    --exclude 'ccache/' \
    --exclude '.repo/' \
    --exclude '*.key' \
    --exclude 'vast_api_key' \
    --exclude 'runpod_api_key' \
    --exclude '.env' \
    --exclude '.env.*' \
    --exclude 'logs/' \
    "${REPO_ROOT}/" \
    "${user}@${host}:${REMOTE_DIR}/"

log "synced. Remote layout:"
ssh_into_pod "find ${REMOTE_DIR} -maxdepth 2 -type d | sort"
