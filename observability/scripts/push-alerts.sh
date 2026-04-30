#!/usr/bin/env bash
# Push all alert rule files under observability/alerts/ to Grafana Cloud Mimir.
#
# Reads:
#   GRAFANA_MIMIR_URL        e.g. https://prometheus-prod-XX-prod-eu-west-2.grafana.net
#   GRAFANA_CLOUD_API_TOKEN  service-account token with rules:write
#   GRAFANA_TENANT_ID        Mimir tenant id

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

if [ -z "${GRAFANA_MIMIR_URL:-}" ] || [ -z "${GRAFANA_CLOUD_API_TOKEN:-}" ] \
    || [ -z "${GRAFANA_TENANT_ID:-}" ]; then
    echo "FAIL: GRAFANA_MIMIR_URL + GRAFANA_CLOUD_API_TOKEN + GRAFANA_TENANT_ID required"
    exit 1
fi

NAMESPACE="${ALERT_NAMESPACE:-mdf}"

for f in observability/alerts/*.yml; do
    name=$(basename "$f" .yml)
    echo "==> push alerts $name -> namespace $NAMESPACE"
    curl -fsS -X POST \
        "${GRAFANA_MIMIR_URL}/api/v1/rules/${NAMESPACE}" \
        -H "Authorization: Bearer ${GRAFANA_CLOUD_API_TOKEN}" \
        -H "X-Scope-OrgID: ${GRAFANA_TENANT_ID}" \
        -H "Content-Type: application/yaml" \
        --data-binary "@$f"
done

echo "==> done"
