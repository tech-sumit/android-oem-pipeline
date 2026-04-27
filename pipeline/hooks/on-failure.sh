#!/usr/bin/env bash
#
# Runs only on a non-zero exit from any phase. Default: dump the tail of the
# most recent build log so the failure is obvious in the streamed Vast.ai
# console output.
#
set -Eeuo pipefail
# shellcheck source=../lib.sh
source "/opt/pipeline/lib.sh"

log_phase "on-failure"

latest_log="$(ls -1t "${LOGS_DIR}"/build-*.log 2>/dev/null | head -1 || true)"
if [[ -n "${latest_log:-}" && -f "$latest_log" ]]; then
    log_warn "tail -200 ${latest_log}:"
    tail -200 "$latest_log" | sed 's/^/  /'
else
    log_warn "no build log found in ${LOGS_DIR}"
fi
