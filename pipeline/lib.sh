#!/usr/bin/env bash
# Common helpers sourced by init.sh and the hooks.
# shellcheck disable=SC2034  # exported helpers are used by sourced scripts.

set -Eeuo pipefail

# ---- logging ---------------------------------------------------------------
# Coloured ANSI logs that survive `docker logs -f` and journald.

_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log_info()  { printf '\033[1;34m[%s] [INFO ]\033[0m %s\n'  "$(_ts)" "$*"; }
log_warn()  { printf '\033[1;33m[%s] [WARN ]\033[0m %s\n'  "$(_ts)" "$*" >&2; }
log_error() { printf '\033[1;31m[%s] [ERROR]\033[0m %s\n'  "$(_ts)" "$*" >&2; }
log_phase() { printf '\033[1;36m[%s] [PHASE]\033[0m === %s ===\n' "$(_ts)" "$*"; }

# Run a hook by name. Hooks live under /opt/pipeline/hooks/<name>.sh.
# Hooks are best-effort: a hook that doesn't exist is a no-op, but a hook
# that exists and exits non-zero aborts the build.
run_hook() {
    local hook="$1"
    local path="/opt/pipeline/hooks/${hook}.sh"
    if [[ -x "$path" ]]; then
        log_phase "hook: ${hook}"
        # shellcheck disable=SC1090
        "$path"
    else
        log_info "hook ${hook}: skipped (no script)"
    fi
}

# Resolve PARALLEL_JOBS: explicit env wins, else nproc.
resolve_jobs() {
    if [[ -n "${PARALLEL_JOBS:-}" ]]; then
        echo "$PARALLEL_JOBS"
    else
        nproc --all
    fi
}

# Compute the Android-style cert filename (subject_hash_old, then ".0").
# Usage: cert_hash_filename /path/to/ca.pem
cert_hash_filename() {
    local pem="$1"
    local hash
    hash=$(openssl x509 -in "$pem" -noout -subject_hash_old)
    echo "${hash}.0"
}

# Make a directory if missing, owned by the build user.
ensure_dir() {
    local d="$1"
    install -d -o "$(id -u)" -g "$(id -g)" "$d"
}
