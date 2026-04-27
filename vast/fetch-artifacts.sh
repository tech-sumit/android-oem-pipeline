#!/usr/bin/env bash
#
# Pull the build outputs (img zip + cvd-host_package.tar.gz + SHA256SUMS) back
# to ${LOCAL_OUT_DIR} (default ./out/<timestamp>/).
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_vastai_auth

REMOTE_OUT="${REMOTE_OUT:-/workspace/aosp-out}"
LOCAL_OUT_DIR="${LOCAL_OUT_DIR:-${REPO_ROOT}/out/$(date -u +%Y%m%dT%H%M%SZ)}"

mkdir -p "$LOCAL_OUT_DIR"

SSH_KEY="$(ssh_key_path)"
IFS=$'\t' read -r user host port < <(current_instance_ssh)

log "rsync ${user}@${host}:${REMOTE_OUT}/  ->  ${LOCAL_OUT_DIR}/"
rsync -azP \
    -e "ssh -i ${SSH_KEY} -p ${port} -o StrictHostKeyChecking=accept-new" \
    "${user}@${host}:${REMOTE_OUT}/" \
    "${LOCAL_OUT_DIR}/"

log "verifying SHA256SUMS"
if [[ -f "${LOCAL_OUT_DIR}/SHA256SUMS" ]]; then
    (cd "$LOCAL_OUT_DIR" && sha256sum -c SHA256SUMS)
else
    warn "no SHA256SUMS file (probably an older build); skipping checksum verify"
fi

log "artifacts at ${LOCAL_OUT_DIR}/"
ls -lh "$LOCAL_OUT_DIR"
