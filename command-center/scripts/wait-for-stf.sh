#!/usr/bin/env bash
# wait-for-stf.sh -- block until the STF main app responds with HTTP 200
# Used by Phase 4 single-instance proof + Phase 4.5 perf baseline.

set -euo pipefail

URL="${1:-http://127.0.0.1:7100}"
TIMEOUT="${2:-180}"

echo "==> waiting for STF at $URL (timeout ${TIMEOUT}s)"
START=$(date +%s)
while true; do
    if curl -sf -o /dev/null --max-time 5 "$URL" ; then
        echo "==> STF is up after $(( $(date +%s) - START ))s"
        exit 0
    fi
    if (( $(date +%s) - START > TIMEOUT )); then
        echo "FAIL: STF did not come up within ${TIMEOUT}s"
        exit 1
    fi
    sleep 2
done
