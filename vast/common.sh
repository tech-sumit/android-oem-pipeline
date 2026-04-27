#!/usr/bin/env bash
# Shared helpers for the vast/ lifecycle scripts.
# Source this from any vast/*.sh.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAST_DIR="${REPO_ROOT}/vast"
INSTANCE_FILE="${VAST_DIR}/.instance_id"
KEY_FILE="${REPO_ROOT}/vast_api_key"
SSH_KEY_DEFAULT="${HOME}/.ssh/id_ed25519_vastai"

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(ts)" "$*"; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$(ts)" "$*" >&2; }
die()  { printf '\033[1;31m[%s]\033[0m %s\n' "$(ts)" "$*" >&2; exit 1; }

require() {
    command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

ensure_vastai_auth() {
    require vastai
    [[ -f "$KEY_FILE" ]] || die "missing API key file: ${KEY_FILE} (echo <key> > vast_api_key && chmod 600 vast_api_key)"
    # 'vastai set api-key' is idempotent and persists to ~/.vast_api_key.
    vastai set api-key "$(cat "$KEY_FILE")" >/dev/null
}

current_instance_id() {
    [[ -f "$INSTANCE_FILE" ]] || die "no active instance (run vast/provision.sh first)"
    cat "$INSTANCE_FILE"
}

# Resolve current instance ssh host:port from `vastai show instance <id>`.
# Echoes "USER HOST PORT" tab-separated.
current_instance_ssh() {
    local id host port
    id="$(current_instance_id)"
    if ! json="$(vastai show instance "$id" --raw 2>/dev/null)"; then
        die "vastai show instance $id failed"
    fi
    host="$(printf '%s' "$json" | python3 -c 'import json,sys;d=json.load(sys.stdin); print(d.get("ssh_host") or d.get("public_ipaddr") or "")')"
    port="$(printf '%s' "$json" | python3 -c 'import json,sys;d=json.load(sys.stdin); print(d.get("ssh_port") or 22)')"
    [[ -n "$host" ]] || die "instance $id has no ssh_host yet (still provisioning?)"
    printf 'root\t%s\t%s\n' "$host" "$port"
}

ssh_key_path() {
    echo "${VAST_SSH_KEY:-$SSH_KEY_DEFAULT}"
}

ssh_into_instance() {
    local user host port key
    IFS=$'\t' read -r user host port < <(current_instance_ssh)
    key="$(ssh_key_path)"
    [[ -f "$key" ]] || die "ssh key not found: $key (ssh-keygen -t ed25519 -f $key)"
    ssh -i "$key" -p "$port" \
        -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=120 \
        "${user}@${host}" "$@"
}

scp_to_instance() {
    local src="$1" dst="$2"
    local user host port key
    IFS=$'\t' read -r user host port < <(current_instance_ssh)
    key="$(ssh_key_path)"
    scp -i "$key" -P "$port" -r -p \
        -o StrictHostKeyChecking=accept-new \
        "$src" "${user}@${host}:${dst}"
}
