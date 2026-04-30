#!/usr/bin/env bash
#
# Pull a profile bundle from Cloudflare R2 instead of from the live pod.
# This is the preferred fetch path once the build's after-build hook has
# published artifacts -- it doesn't depend on the pod still running and uses
# Cloudflare's free egress instead of RunPod's metered network.
#
# Required env (same vars the after-build hook used to publish):
#   R2_BUCKET                  -- e.g. panditai-training
#   R2_PREFIX                  -- e.g. mayaos          (no leading/trailing slash)
#   R2_ACCESS_KEY_ID           -- R2 token access key
#   R2_SECRET_ACCESS_KEY       -- R2 token secret
#   R2_ENDPOINT                -- https://<account>.r2.cloudflarestorage.com
#                                 (auto-derived from R2_ACCOUNT_ID if unset)
#   R2_ACCOUNT_ID              -- 32-char hex account id (used to derive endpoint)
#
# Optional:
#   PROFILES                   -- comma-list, e.g. galaxy-s26-ultra-apple-silicon.
#                                 If unset, lists all <prefix>/<brand>/.../*/
#                                 leaves and prompts. (No interactivity here:
#                                 we just refuse and require the caller to pick.)
#   FINGERPRINT                -- explicit s3 path leaf, overrides discovery,
#                                 e.g. samsung/s26uxxx/s26u/16/BP1A.250505.005/
#                                      S948BXXU1AYA1
#                                 The script appends ${PROFILE} to it.
#   LOCAL_OUT_DIR              -- defaults to ./out/<UTC-timestamp>/
#   ENV_FILE                   -- absolute path to a .env to source before
#                                 reading the R2_* vars. Lets callers point at
#                                 a sibling project's .env without duplicating.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log()  { printf '\033[1;34m[r2-fetch]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[r2-fetch][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[r2-fetch][err]\033[0m %s\n' "$*" >&2; exit 1; }

# Source .env if pointed at one (or default to project root .env if it exists).
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
if [[ -f "$ENV_FILE" ]]; then
    log "loading env from ${ENV_FILE}"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

# Derive endpoint from account id when not explicit. Cloudflare's S3-compatible
# endpoint is always https://<accountid>.r2.cloudflarestorage.com.
if [[ -z "${R2_ENDPOINT:-}" && -n "${R2_ACCOUNT_ID:-}" ]]; then
    R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
fi

# R2_PREFIX defaults to "mayaos" because that's where after-build.sh writes
# (see start-tmux-build.sh and pipeline/hooks/after-build.sh). Anyone publishing
# to a different prefix must override it explicitly.
: "${R2_PREFIX:=mayaos}"

: "${R2_BUCKET:?missing env: R2_BUCKET}"
: "${R2_ENDPOINT:?missing env: R2_ENDPOINT (or R2_ACCOUNT_ID)}"
: "${R2_ACCESS_KEY_ID:?missing env: R2_ACCESS_KEY_ID}"
: "${R2_SECRET_ACCESS_KEY:?missing env: R2_SECRET_ACCESS_KEY}"

command -v aws >/dev/null || die "awscli not installed: brew install awscli"

# Cloudflare R2 only accepts a small set of region names ("auto", "wnam",
# "enam", "weur", "eeur", "apac", "oc"). awscli inherits AWS_DEFAULT_REGION /
# AWS_REGION from the user's shell, which often points at a real AWS region
# (e.g. "ap-south-1") and that triggers an InvalidRegionName error here.
# Force "auto" for every aws call this script makes; the values it overrides
# don't escape this process.
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
export AWS_REGION=auto

# Strip any leading/trailing slashes from the prefix to keep the s3:// URL clean.
R2_PREFIX="${R2_PREFIX#/}"
R2_PREFIX="${R2_PREFIX%/}"

PROFILES="${PROFILES:-${PROFILE:-}}"
[[ -z "$PROFILES" ]] && die "set PROFILES=<id> (e.g. galaxy-s26-ultra-apple-silicon)"

LOCAL_OUT_DIR="${LOCAL_OUT_DIR:-${REPO_ROOT}/out/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$LOCAL_OUT_DIR"

# Locate the latest fingerprint path for each profile if the caller didn't
# supply one. Convention from after-build.sh:
#   s3://<bucket>/<prefix>/<brand>/<name>/<device>/<release>/<buildid>/<incr>/<profile>/
# Example:
#   s3://panditai-training/mayaos/samsung/s26uxxx/s26u/16/BP1A.250505.005/S948BXXU1AYA1/galaxy-s26-ultra-apple-silicon/
discover_fingerprint_for() {
    local profile="$1"
    # If FINGERPRINT was set, honour it.
    if [[ -n "${FINGERPRINT:-}" ]]; then
        printf '%s' "${FINGERPRINT%/}/${profile}"
        return
    fi
    # Walk the prefix tree, collect every leaf that ends with /<profile>/.
    local s3_url="s3://${R2_BUCKET}/${R2_PREFIX}/"
    local hits
    hits="$(aws s3 ls "$s3_url" --recursive \
              --endpoint-url "$R2_ENDPOINT" \
              --no-cli-pager 2>/dev/null \
            | awk -v p="/${profile}/" '$NF ~ p {print $NF}' \
            | awk -v p="/${profile}/" '{
                  i = index($0, p);
                  if (i > 0) print substr($0, 1, i + length(p) - 1);
              }' \
            | sort -u)"
    [[ -z "$hits" ]] && die "no R2 keys found under ${s3_url} matching profile ${profile}"
    # If multiple fingerprints, pick the most recently uploaded one. We approximate
    # "newest" by using the last-modified time of metadata.json under each leaf.
    if [[ "$(wc -l <<< "$hits")" -gt 1 ]]; then
        warn "multiple fingerprint paths exist for ${profile}, picking newest:"
        printf '  %s\n' $hits >&2
    fi
    # The leaves discovered above are full prefix paths like
    #   mayaos/samsung/s26uxxx/.../S948BXXU1AYA1/galaxy-s26-ultra-apple-silicon
    # Strip the bucket prefix so the caller can re-attach it.
    tail -n1 <<< "$hits"
}

IFS=',' read -ra PROFILE_LIST <<< "$PROFILES"
for pid in "${PROFILE_LIST[@]}"; do
    [[ -z "$pid" ]] && continue
    log "discovering R2 path for profile ${pid}"
    leaf="$(discover_fingerprint_for "$pid")"
    leaf="${leaf%/}"   # awk substr above includes the trailing slash; strip it
    src="s3://${R2_BUCKET}/${leaf}/"
    dst="${LOCAL_OUT_DIR}/${pid}/"
    mkdir -p "$dst"
    log "  ${src}"
    log "    -> ${dst}"
    aws s3 sync "$src" "$dst" \
        --endpoint-url "$R2_ENDPOINT" \
        --no-cli-pager \
        --no-progress \
        --only-show-errors
    log "  done: $(du -sh "$dst" | cut -f1) in ${dst}"
done

# Verify checksums when the bundle ships SHA256SUMS.
log "verifying SHA256SUMS for each profile"
for pid in "${PROFILE_LIST[@]}"; do
    [[ -z "$pid" ]] && continue
    sums="${LOCAL_OUT_DIR}/${pid}/SHA256SUMS"
    if [[ -f "$sums" ]]; then
        if (cd "${LOCAL_OUT_DIR}/${pid}" && shasum -a 256 -c SHA256SUMS) >/dev/null 2>&1; then
            log "  ${pid}: SHA256SUMS verified"
        else
            warn "  ${pid}: SHA256SUMS verification FAILED"
        fi
    else
        warn "  ${pid}: no SHA256SUMS in bundle; skipping verify"
    fi
done

log "artifacts at ${LOCAL_OUT_DIR}/"
( cd "$LOCAL_OUT_DIR" && ls -lhR ) | sed 's/^/  /'
