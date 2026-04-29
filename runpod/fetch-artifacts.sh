#!/usr/bin/env bash
#
# Pull the build outputs (img zip + cvd-host_package.tar.gz + SHA256SUMS) back
# to ${LOCAL_OUT_DIR} (default ./out/<timestamp>/).
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_runpod_auth

# /workspace/aosp-out is a symlink to /workspace/aosp-src/out (the full AOSP
# build tree, ~80+ GB of intermediates we don't want). The build's after-build
# hook bundles each profile into out/<profile-id>/, which is the only thing
# worth pulling. PROFILES (or PROFILE) lets the caller scope the fetch.
REMOTE_OUT_BASE="${REMOTE_OUT_BASE:-/workspace/aosp-src/out}"
LOCAL_OUT_DIR="${LOCAL_OUT_DIR:-${REPO_ROOT}/out/$(date -u +%Y%m%dT%H%M%SZ)}"
PROFILES="${PROFILES:-${PROFILE:-}}"

mkdir -p "$LOCAL_OUT_DIR"

SSH_KEY="$(ssh_key_path)"
IFS=$'\t' read -r user host port < <(current_pod_ssh)

# Discover profile dirs to pull. If PROFILES is set, use it; otherwise list
# every <profile-id>/ subdir on the pod that has the standard bundle layout
# (i.e. contains build-fingerprint.txt or a *-img-*.zip).
declare -a PROFILE_LIST
if [[ -n "$PROFILES" ]]; then
    IFS=',' read -ra PROFILE_LIST <<< "$PROFILES"
else
    log "discovering profile bundle dirs under ${REMOTE_OUT_BASE}/"
    mapfile -t PROFILE_LIST < <(ssh_into_pod \
        "ls -1d ${REMOTE_OUT_BASE}/*/ 2>/dev/null \
         | xargs -I{} bash -c 'd={}; [ -e \"\$d\"build-fingerprint.txt -o -n \"\$(ls \"\$d\"*-img-*.zip 2>/dev/null)\" ] && basename \"\${d%/}\"'")
fi

if [[ ${#PROFILE_LIST[@]} -eq 0 ]]; then
    die "no profile bundle dirs found under ${REMOTE_OUT_BASE}/ on the pod;" \
        "either the build hasn't finished or pass PROFILES=<id1,id2>"
fi

log "fetching profile bundles: ${PROFILE_LIST[*]}"
for pid in "${PROFILE_LIST[@]}"; do
    [[ -z "$pid" ]] && continue
    src="${REMOTE_OUT_BASE}/${pid}/"
    dst="${LOCAL_OUT_DIR}/${pid}/"
    mkdir -p "$dst"
    log "  rsync ${user}@${host}:${src}  ->  ${dst}"
    rsync -azP \
        -e "ssh -i ${SSH_KEY} -p ${port} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
        "${user}@${host}:${src}" \
        "${dst}"
done

log "verifying SHA256SUMS for each profile"
for pid in "${PROFILE_LIST[@]}"; do
    [[ -z "$pid" ]] && continue
    sums="${LOCAL_OUT_DIR}/${pid}/SHA256SUMS"
    if [[ -f "$sums" ]]; then
        (cd "${LOCAL_OUT_DIR}/${pid}" && sha256sum -c SHA256SUMS) \
            && log "  ${pid}: SHA256SUMS verified" \
            || warn "  ${pid}: SHA256SUMS verification FAILED"
    else
        warn "  ${pid}: no SHA256SUMS (older build); skipping checksum verify"
    fi
done

log "artifacts at ${LOCAL_OUT_DIR}/"
# Portable listing: macOS `find` lacks GNU's -printf, so use ls -lhR instead.
( cd "$LOCAL_OUT_DIR" && ls -lhR ) | sed 's/^/  /'
