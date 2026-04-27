#!/usr/bin/env bash
#
# Rent the Vast.ai offer specified on the command line, save its instance id,
# wait for SSH to come up, then add the host to known_hosts.
#
# Usage: ./vast/provision.sh <offer_id>
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_vastai_auth

OFFER_ID="${1:-}"
[[ -n "$OFFER_ID" ]] || die "usage: $0 <offer_id> (run vast/search.sh first)"

# We boot Ubuntu 22.04 with a generous /workspace volume. The image is the
# vanilla Vast Ubuntu image -- our Dockerfile is built ON the instance from
# vast/sync-source.sh + vast/kick-build.sh, not pre-baked.
IMAGE="${VAST_IMAGE:-ubuntu:22.04}"
DISK_GB="${DISK_GB:-1024}"
LABEL="${VAST_LABEL:-mayaos-aosp-builder}"

# Inject our SSH pubkey so we can ssh in without password.
SSH_KEY="$(ssh_key_path)"
if [[ ! -f "${SSH_KEY}.pub" ]]; then
    log "no ssh keypair at ${SSH_KEY}; generating..."
    ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" -C "vast.ai mayaos build $(date -u +%F)"
fi

log "creating Vast.ai instance from offer ${OFFER_ID} (image=${IMAGE}, disk=${DISK_GB}G)"

CREATE_JSON=$(vastai create instance "$OFFER_ID" \
    --image "$IMAGE" \
    --disk "$DISK_GB" \
    --label "$LABEL" \
    --ssh \
    --direct \
    --raw)

NEW_ID=$(printf '%s' "$CREATE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["new_contract"])')
[[ -n "$NEW_ID" && "$NEW_ID" != "None" ]] || die "create instance failed: $CREATE_JSON"

echo "$NEW_ID" > "$INSTANCE_FILE"
log "instance id: ${NEW_ID} (saved to ${INSTANCE_FILE})"

# Push our SSH pubkey via the Vast API (works before the instance has booted).
log "registering SSH pubkey with instance ${NEW_ID}"
vastai attach ssh "$NEW_ID" "$(cat "${SSH_KEY}.pub")" >/dev/null

log "waiting for instance to reach 'running' state (polling every 10s)..."
for i in $(seq 1 60); do
    state=$(vastai show instance "$NEW_ID" --raw 2>/dev/null \
        | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("actual_status") or d.get("intended_status") or "?")')
    case "$state" in
        running)  log "  state=running"; break ;;
        loading|created|scheduling) log "  state=${state} (try ${i}/60)" ;;
        *) warn "  state=${state} (try ${i}/60)" ;;
    esac
    sleep 10
done

# Wait for SSH listener to be reachable.
log "waiting for SSH to accept connections..."
for i in $(seq 1 60); do
    if ssh_into_instance true 2>/dev/null; then
        log "  ssh ok"
        break
    fi
    sleep 5
done

ssh_into_instance 'cat /etc/os-release | grep PRETTY_NAME; nproc; free -g | head -2; df -h /'

log "instance ${NEW_ID} is ready."
log "next steps:"
log "  ./vast/sync-source.sh   # rsync this repo to the instance"
log "  ./vast/kick-build.sh    # docker build + run the AOSP build container"
