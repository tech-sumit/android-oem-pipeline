#!/usr/bin/env bash
# Shared helpers for the runpod/ lifecycle scripts.
# Source this from any runpod/*.sh.
#
# RunPod is the second-source compute backend for the AOSP build (the first
# being vast/). Why both:
#   - Vast.ai marketplace offers can be reclaimed mid-build.
#   - RunPod SECURE pods come with a public IP, persistent /workspace volume,
#     and an SLA, which fits the 5-7 hour AOSP cold build much better.
#   - Same pipeline/ scripts run on either backend; only the lifecycle
#     scripts differ.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNPOD_DIR="${REPO_ROOT}/runpod"
POD_FILE="${RUNPOD_DIR}/.pod_id"
KEY_FILE="${REPO_ROOT}/runpod_api_key"
SSH_KEY_DEFAULT="${HOME}/.ssh/id_ed25519_runpod"

RUNPOD_API="${RUNPOD_API:-https://rest.runpod.io/v1}"

ts()   { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(ts)" "$*"; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$(ts)" "$*" >&2; }
die()  { printf '\033[1;31m[%s]\033[0m %s\n' "$(ts)" "$*" >&2; exit 1; }

require() {
    command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

ensure_runpod_auth() {
    require curl
    require jq

    if [[ -z "${RUNPOD_API_KEY:-}" ]]; then
        if [[ -f "$KEY_FILE" ]]; then
            RUNPOD_API_KEY="$(tr -d ' \t\r\n' < "$KEY_FILE")"
            export RUNPOD_API_KEY
        elif [[ -f "${HOME}/.config/runpod/api_key" ]]; then
            RUNPOD_API_KEY="$(tr -d ' \t\r\n' < "${HOME}/.config/runpod/api_key")"
            export RUNPOD_API_KEY
        fi
    fi

    [[ -n "${RUNPOD_API_KEY:-}" ]] || die "no RunPod credentials found. Either:
       - export RUNPOD_API_KEY=<your_key>, or
       - drop your key into ${KEY_FILE} and chmod 600
       (the key starts with 'rpa_' and lives at https://www.runpod.io/console/user/settings)"
}

# Make a GET against the RunPod REST API. Pipes JSON body to stdout.
runpod_get() {
    local path="$1"
    curl -fsSL \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -H "Accept: application/json" \
        "${RUNPOD_API}${path}"
}

# Make a POST against the RunPod REST API. $1=path, $2=JSON body.
runpod_post() {
    local path="$1" body="$2"
    curl -fsSL -X POST \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$body" \
        "${RUNPOD_API}${path}"
}

# Make a DELETE against the RunPod REST API.
runpod_delete() {
    local path="$1"
    curl -fsSL -X DELETE \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -H "Accept: application/json" \
        "${RUNPOD_API}${path}"
}

current_pod_id() {
    [[ -f "$POD_FILE" ]] || die "no active pod (run runpod/provision.sh first)"
    tr -d ' \t\r\n' < "$POD_FILE"
}

# Resolve the active pod's SSH endpoint from the API. Echoes "USER<TAB>HOST<TAB>PORT".
# Caches the result for the duration of the calling script via the env var
# RUNPOD_SSH_CACHE so we don't hit the API on every helper call.
current_pod_ssh() {
    local id json host port
    id="$(current_pod_id)"

    if [[ -n "${RUNPOD_SSH_CACHE:-}" ]]; then
        printf '%s\n' "$RUNPOD_SSH_CACHE"
        return 0
    fi

    if ! json="$(runpod_get "/pods/${id}" 2>/dev/null)"; then
        die "RunPod GET /pods/${id} failed (is the pod still alive?)"
    fi

    host="$(printf '%s' "$json" | jq -r '.publicIp // empty')"
    # portMappings is an object like {"22": 12345}. The 22 key may be a string.
    port="$(printf '%s' "$json" | jq -r '.portMappings["22"] // .portMappings."22" // empty')"

    if [[ -z "$host" || -z "$port" ]]; then
        local status
        status="$(printf '%s' "$json" | jq -r '.desiredStatus // .status // "unknown"')"
        die "pod ${id} has no SSH endpoint yet (status=${status}, publicIp=${host:-?}, port=${port:-?}). Wait for it to finish provisioning."
    fi

    RUNPOD_SSH_CACHE="$(printf 'root\t%s\t%s' "$host" "$port")"
    export RUNPOD_SSH_CACHE
    printf '%s\n' "$RUNPOD_SSH_CACHE"
}

ssh_key_path() {
    echo "${RUNPOD_SSH_KEY:-$SSH_KEY_DEFAULT}"
}

ensure_ssh_key() {
    local key="$1"
    if [[ ! -f "${key}.pub" ]]; then
        log "no SSH keypair at ${key}; generating ed25519 keypair"
        ssh-keygen -t ed25519 -N '' -f "$key" -C "runpod mayaos build $(date -u +%F)"
    fi
}

ssh_into_pod() {
    local user host port key
    IFS=$'\t' read -r user host port < <(current_pod_ssh)
    key="$(ssh_key_path)"
    [[ -f "$key" ]] || die "ssh key not found: $key (ssh-keygen -t ed25519 -f $key)"
    ssh -i "$key" -p "$port" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=120 \
        "${user}@${host}" "$@"
}

scp_to_pod() {
    local src="$1" dst="$2"
    local user host port key
    IFS=$'\t' read -r user host port < <(current_pod_ssh)
    key="$(ssh_key_path)"
    scp -i "$key" -P "$port" -r -p \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$src" "${user}@${host}:${dst}"
}
