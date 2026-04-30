#!/usr/bin/env bash
# mdf-status.sh -- show the state of every fleet pod.
#
# Reads ``terraform state`` for the list of pods, then SSH-fans-out to
# each one and asks supervisord for the status of every process. Also
# pulls the device count from STF's REST API so you get an at-a-glance
# "how many devices are alive" view.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

if ! command -v terraform >/dev/null 2>&1; then
    echo "FAIL: terraform not in PATH"; exit 1
fi

PODS_JSON=$(cd mdf/terraform && terraform output -json pods 2>/dev/null || echo '[]')
if [ "$PODS_JSON" = '[]' ]; then
    echo "no pods provisioned (try: make mdf-provision)"
    exit 0
fi

echo "==> MDF fleet status"
printf '%-25s  %-22s  %-9s  %-7s  %s\n' \
    "POD" "URL" "DEVICES" "PROC" "TUNNEL"

echo "$PODS_JSON" | jq -c '.[]' | while read -r pod; do
    name=$(echo "$pod"      | jq -r .name)
    ssh_host=$(echo "$pod"  | jq -r .ssh_host)
    ssh_port=$(echo "$pod"  | jq -r .ssh_port)
    public_url=$(echo "$pod"| jq -r .public_url)
    devices="?"
    procs="?"
    tunnel="?"
    if ssh -p "$ssh_port" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
            "root@$ssh_host" 'docker compose -f /opt/mdf/command-center/docker-compose.fleet.yml ps' >/dev/null 2>&1; then
        devices=$(curl -sf --max-time 4 "$public_url/api/v1/devices" \
                  -H "Authorization: Bearer ${MDF_API_TOKEN:-}" \
                  | jq -r '.devices | length' 2>/dev/null || echo "?")
        procs=$(ssh -p "$ssh_port" "root@$ssh_host" \
                'docker compose -f /opt/mdf/command-center/docker-compose.fleet.yml exec -T mdf supervisorctl status 2>/dev/null | grep RUNNING | wc -l' 2>/dev/null || echo "?")
        tunnel=$(ssh -p "$ssh_port" "root@$ssh_host" \
                 'docker compose -f /opt/mdf/command-center/docker-compose.fleet.yml ps mdf-tunnel --format json 2>/dev/null | jq -r .[0].State' 2>/dev/null || echo "?")
    fi
    printf '%-25s  %-22s  %-9s  %-7s  %s\n' \
        "$name" "$(echo "$public_url" | sed 's|https://||')" \
        "$devices" "$procs" "$tunnel"
done
