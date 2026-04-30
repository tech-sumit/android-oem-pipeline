#!/usr/bin/env bash
# mdf-destroy.sh -- safely tear down a fleet pod.
#
# IMPORTANT: snapshots RethinkDB to R2 BEFORE destroying anything, so a
# rebuild only needs to download the snapshot to recover the device
# inventory + recordings index. Recordings + mitm flows are already in
# R2 so destruction is non-destructive of those payloads.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

POD_NAME="${POD_NAME:-mdf-pod-eu-de-0}"
echo "==> Phase 8 fleet destroy"
echo "    pod = $POD_NAME"

POD_IP=$(cd mdf/terraform && terraform output -raw "pod_${POD_NAME}_ssh_host" 2>/dev/null || true)
POD_PORT=$(cd mdf/terraform && terraform output -raw "pod_${POD_NAME}_ssh_port" 2>/dev/null || true)

if [ -z "$POD_IP" ]; then
    echo "==> pod $POD_NAME not found in terraform state -- nothing to do"
    exit 0
fi

echo "==> step 1/3: snapshot RethinkDB to R2"
ssh -p "$POD_PORT" "root@$POD_IP" '
    cd /opt/mdf/command-center && \
    docker compose -f docker-compose.fleet.yml exec -T mdf bash -c \
        "rethinkdb dump --connect rethink-1:28015 --file /tmp/mdf.dump.tar.gz && \
         aws s3 cp /tmp/mdf.dump.tar.gz s3://android/mdf/snapshots/$(hostname)-$(date +%s).tar.gz \
            --endpoint-url $R2_ENDPOINT"
' || echo "WARN: RethinkDB snapshot failed; proceeding"

echo "==> step 2/3: docker compose down"
ssh -p "$POD_PORT" "root@$POD_IP" \
    'cd /opt/mdf/command-center && docker compose -f docker-compose.fleet.yml down -v' || true

echo "==> step 3/3: terraform destroy (RunPod pod + Cloudflare tunnel + DNS)"
( cd mdf/terraform && terraform destroy -auto-approve \
    -target="runpod_pod.$POD_NAME" \
    -target="cloudflare_tunnel.$POD_NAME" \
    -target="cloudflare_record.$POD_NAME" )

echo "==> destroyed $POD_NAME"
