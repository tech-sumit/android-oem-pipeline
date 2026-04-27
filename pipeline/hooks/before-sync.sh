#!/usr/bin/env bash
# Phase 1: before repo init/sync.
#
# Default: no-op. Override by mounting your own script at
# /opt/pipeline/hooks/before-sync.sh.
#
# Common uses:
#   - Pre-warm a git mirror to speed up sync.
#   - Apply repo manifest patches.
#   - Set up SSH keys for private mirrors.

set -Eeuo pipefail
# shellcheck source=../lib.sh
source "/opt/pipeline/lib.sh"

log_info "before-sync: nothing to do (default)"
