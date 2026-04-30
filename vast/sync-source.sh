#!/usr/bin/env bash
#
# rsync this repository (Dockerfile + pipeline + aosp-tree + ca + manifests)
# to the active Vast.ai instance under /workspace/android-oem-pipeline.
#
# Excludes:
#   - .git/                  not needed on the build host
#   - vast/                  Vast.ai control-plane scripts; only relevant locally
#   - out/, ccache/, .repo/  large state, lives on the instance
#   - *.key, vast_api_key    secrets stay local
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_vastai_auth
require rsync

SSH_KEY="$(ssh_key_path)"
IFS=$'\t' read -r user host port < <(current_instance_ssh)

REMOTE_DIR="${REMOTE_DIR:-/workspace/android-oem-pipeline}"

log "rsync ${REPO_ROOT} -> ${user}@${host}:${REMOTE_DIR}"

ssh_into_instance "mkdir -p ${REMOTE_DIR}"

rsync -azP --delete \
    -e "ssh -i ${SSH_KEY} -p ${port} -o StrictHostKeyChecking=accept-new" \
    --exclude '.git/' \
    --exclude 'vast/' \
    --exclude 'out/' \
    --exclude 'ccache/' \
    --exclude '.repo/' \
    --exclude '*.key' \
    --exclude 'vast_api_key' \
    --exclude '.env' \
    --exclude '.env.*' \
    --exclude 'logs/' \
    "${REPO_ROOT}/" \
    "${user}@${host}:${REMOTE_DIR}/"

log "synced. Remote layout:"
ssh_into_instance "find ${REMOTE_DIR} -maxdepth 2 -type d | sort"
