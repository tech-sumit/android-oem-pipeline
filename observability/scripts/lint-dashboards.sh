#!/usr/bin/env bash
# Lint the dashboard JSON: valid JSON, unique UIDs, no nameless panels.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

errors=0
declare -a seen_uids=()

for dash in observability/dashboards/*.json; do
    if ! jq empty "$dash" 2>/dev/null; then
        echo "FAIL: $dash is not valid JSON"; errors=$((errors+1)); continue
    fi
    uid=$(jq -r '.uid // empty' "$dash")
    if [ -z "$uid" ]; then
        echo "FAIL: $dash has no .uid"; errors=$((errors+1)); continue
    fi
    dup=0
    for u in "${seen_uids[@]:-}"; do
        [ "$u" = "$uid" ] && dup=1
    done
    if [ $dup -eq 1 ]; then
        echo "FAIL: $dash duplicates uid $uid"; errors=$((errors+1)); continue
    fi
    seen_uids+=("$uid")
    panels_no_title=$(jq '[.panels[] | select(.title==null or .title=="")] | length' "$dash")
    if [ "$panels_no_title" -gt 0 ]; then
        echo "WARN: $dash has $panels_no_title panel(s) without a title"
    fi
done

if [ $errors -gt 0 ]; then
    echo "FAIL: $errors dashboard error(s)"; exit 1
fi
echo "ok: $(ls observability/dashboards/*.json | wc -l) dashboards lint clean"
