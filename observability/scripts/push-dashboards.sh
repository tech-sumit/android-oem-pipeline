#!/usr/bin/env bash
# Push all dashboards under observability/dashboards/ to Grafana Cloud.
#
# Reads:
#   GRAFANA_CLOUD_URL        e.g. https://mayaos.grafana.net
#   GRAFANA_CLOUD_API_TOKEN  service-account token with editor scope

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

if [ -z "${GRAFANA_CLOUD_URL:-}" ] || [ -z "${GRAFANA_CLOUD_API_TOKEN:-}" ]; then
    echo "FAIL: GRAFANA_CLOUD_URL + GRAFANA_CLOUD_API_TOKEN required"; exit 1
fi

for dash in observability/dashboards/*.json; do
    echo "==> push $dash"
    body=$(jq -c --argjson dashboard "$(cat "$dash")" \
        '{ dashboard: $dashboard, overwrite: true, message: "auto-push from MDF repo" }' \
        <<<'{}')
    curl -fsS -XPOST "${GRAFANA_CLOUD_URL}/api/dashboards/db" \
        -H "Authorization: Bearer ${GRAFANA_CLOUD_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$body" | jq -r '"   uid=\(.uid) version=\(.version) status=\(.status)"'
done
