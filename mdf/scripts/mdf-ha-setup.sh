#!/usr/bin/env bash
# mdf-ha-setup.sh -- bring up a 2-pod HA fleet.
#
# Steps:
#   1. Provision pod-0 (acts as RethinkDB primary + STF app).
#   2. Provision pod-1 (RethinkDB secondary; joins via 29015).
#   3. Configure RethinkDB tables for replicas=2, write_acks="majority"
#      so a single-pod failure does NOT cause data loss (rev 5.1 §10).
#   4. Validate by killing pod-0 mdf container and confirming pod-1
#      keeps serving (with degraded throughput).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

POD0_HOST="${POD0_HOST:?POD0_HOST required, e.g. mdf-pod-eu-de-0}"
POD1_HOST="${POD1_HOST:?POD1_HOST required, e.g. mdf-pod-eu-de-1}"

echo "==> Phase 10 HA bring-up"
echo "    pod-0 = $POD0_HOST  (RethinkDB primary)"
echo "    pod-1 = $POD1_HOST  (RethinkDB secondary)"

# --- 1. provision pod-0 -------------------------------------------------
echo "==> step 1/4: provision pod-0"
MDF_HOSTNAME="$POD0_HOST" make mdf-provision

# --- 2. provision pod-1 -------------------------------------------------
echo "==> step 2/4: provision pod-1"
POD0_IP=$(cd mdf/terraform && terraform output -raw "pod_${POD0_HOST}_ssh_host")
RETHINK_JOIN_FLAG="--join ${POD0_IP}:29015" \
    MDF_HOSTNAME="$POD1_HOST" make mdf-provision

# --- 3. set replicas + write acks --------------------------------------
echo "==> step 3/4: reshape RethinkDB for HA"
ssh "root@${POD0_IP}" \
    "docker compose -f /opt/mdf/command-center/docker-compose.ha.yml exec -T rethink \
     rethinkdb-cli --bind all -e \
     \"r.db('mdf').tableList().forEach(function(t) { return r.db('mdf').table(t).reconfigure({replicas: 2, shards: 1, primaryReplicaTag: 'default'}); }).run()\""
ssh "root@${POD0_IP}" \
    "docker compose -f /opt/mdf/command-center/docker-compose.ha.yml exec -T rethink \
     rethinkdb-cli --bind all -e \
     \"r.db('mdf').tableList().forEach(function(t) { return r.db('mdf').table(t).config().update({write_acks: 'majority', durability: 'hard'}); }).run()\""

# --- 4. failover smoke test --------------------------------------------
echo "==> step 4/4: failover smoke test"
echo "    killing pod-0 mdf container..."
ssh "root@${POD0_IP}" 'docker kill mdf' || true
sleep 10
POD1_IP=$(cd mdf/terraform && terraform output -raw "pod_${POD1_HOST}_ssh_host")
if curl -sf "https://${POD1_HOST}.mdf.mayaos.dev/api/v1/devices" > /dev/null; then
    echo "    pod-1 still serving requests. HA OK."
else
    echo "FAIL: pod-1 not serving after pod-0 went down"
    exit 1
fi
echo "    restarting pod-0..."
ssh "root@${POD0_IP}" 'cd /opt/mdf/command-center && docker compose -f docker-compose.ha.yml up -d mdf'

echo "==> Phase 10 HA bring-up complete."
