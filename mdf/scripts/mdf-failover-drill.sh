#!/usr/bin/env bash
# mdf-failover-drill.sh -- regular failover drill for the HA fleet.
#
# Cron candidate: monthly. Validates the assumption that pod-1 will
# in fact serve traffic when pod-0 is unavailable. Records latency +
# detected lost-write count to docs/ha-drill-history.md.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

POD0_HOST="${POD0_HOST:?POD0_HOST required}"
POD1_HOST="${POD1_HOST:?POD1_HOST required}"

echo "==> failover drill at $(date -u +%FT%TZ)"

POD0_IP=$(cd mdf/terraform && terraform output -raw "pod_${POD0_HOST}_ssh_host")
POD1_URL="https://${POD1_HOST}.mdf.mayaos.dev"

# 1. write a marker into RethinkDB via pod-0
echo "==> step 1: write marker via pod-0"
MARKER="drill-$(date +%s)"
curl -sf -XPOST "https://${POD0_HOST}.mdf.mayaos.dev/mdf/ota-channel/channels/$MARKER" \
     -H 'Content-Type: application/json' \
     -d '{"source":"failover-drill"}' >/dev/null

# 2. kill pod-0 mdf container
echo "==> step 2: kill pod-0 mdf container"
ssh "root@${POD0_IP}" 'docker kill mdf' || true

# 3. read marker via pod-1 and time it
echo "==> step 3: read marker via pod-1"
START=$(date +%s%3N)
RESP=$(curl -s -o /tmp/resp.json -w '%{http_code}' "${POD1_URL}/mdf/ota-channel/channels")
END=$(date +%s%3N)
LAT_MS=$((END - START))

if [ "$RESP" = "200" ] && jq -e ".channels.\"$MARKER\"" /tmp/resp.json >/dev/null 2>&1; then
    echo "    PASS: pod-1 returned marker in ${LAT_MS}ms"
    OUTCOME="pass"
else
    echo "    FAIL: pod-1 did NOT return marker (http=$RESP, lat=${LAT_MS}ms)"
    OUTCOME="fail"
fi

# 4. restart pod-0
echo "==> step 4: restart pod-0"
ssh "root@${POD0_IP}" 'cd /opt/mdf/command-center && docker compose -f docker-compose.ha.yml up -d mdf'

# 5. record drill
mkdir -p docs
{
    echo "| $(date -u +%FT%TZ) | $POD0_HOST -> $POD1_HOST | $OUTCOME | ${LAT_MS}ms |"
} >> docs/ha-drill-history.md

echo "==> drill recorded; outcome = $OUTCOME"
