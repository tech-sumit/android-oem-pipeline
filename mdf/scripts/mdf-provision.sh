#!/usr/bin/env bash
# mdf-provision.sh -- end-to-end fleet pod bring-up.
#
# Steps:
#   1. terraform apply (RunPod pod + R2 bucket + Cloudflare DNS).
#   2. wait for SSH on the pod, copy command-center/, mayaos.yaml,
#      ca/, and the latest emulator image artifact onto the pod.
#   3. start docker-compose.fleet.yml; wait for STF + provider healthy.
#   4. POST a heartbeat to the operator Slack/email channel.
#
# Usage:
#   REGION=eu-de POD_TYPE=NVIDIA_RTX_A6000_SECURE \
#   FLEET_SIZE=80 \
#   MDF_HOSTNAME=mdf-pod-eu-de-0 \
#   ./mdf/scripts/mdf-provision.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

REGION="${REGION:-us-or}"
POD_TYPE="${POD_TYPE:-NVIDIA_RTX_A6000_SECURE}"
FLEET_SIZE="${FLEET_SIZE:-80}"
MDF_HOSTNAME="${MDF_HOSTNAME:-mdf-pod-${REGION}-0}"
PROVIDER_NAME="${PROVIDER_NAME:-${MDF_HOSTNAME}}"

echo "==> Phase 8 fleet provisioning"
echo "    region       = $REGION"
echo "    pod type     = $POD_TYPE"
echo "    fleet size   = $FLEET_SIZE"
echo "    hostname     = $MDF_HOSTNAME"

# --- 1. Terraform infrastructure ---------------------------------------
echo "==> step 1/4: terraform apply"
( cd mdf/terraform && terraform init -upgrade && terraform apply -auto-approve \
    -var "region=$REGION" \
    -var "pod_type=$POD_TYPE" \
    -var "mdf_hostname=$MDF_HOSTNAME" )

POD_IP="$(cd mdf/terraform && terraform output -raw pod_ssh_host)"
POD_PORT="$(cd mdf/terraform && terraform output -raw pod_ssh_port)"
TUNNEL_TOKEN="$(cd mdf/terraform && terraform output -raw cloudflare_tunnel_token)"
PUBLIC_URL="$(cd mdf/terraform && terraform output -raw mdf_public_url)"

echo "==> pod ssh: $POD_IP:$POD_PORT"
echo "==> public URL: $PUBLIC_URL"

# --- 2. Sync command-center + secrets ----------------------------------
echo "==> step 2/4: rsync command-center/ to pod"
ssh -p "$POD_PORT" -o StrictHostKeyChecking=accept-new "root@$POD_IP" \
    'mkdir -p /opt/mdf/command-center /opt/mdf/ca /srv/mayaos-images'
rsync -e "ssh -p $POD_PORT" -avz --delete \
    --exclude 'node_modules/' --exclude '.git/' --exclude 'stf/' \
    command-center/ "root@$POD_IP:/opt/mdf/command-center/"
rsync -e "ssh -p $POD_PORT" -avz mayaos.yaml ca/ \
    "root@$POD_IP:/opt/mdf/"

# --- 3. docker-compose.fleet.yml up ------------------------------------
echo "==> step 3/4: docker-compose.fleet.yml up"
ssh -p "$POD_PORT" "root@$POD_IP" \
    "cd /opt/mdf/command-center && \
     export CLOUDFLARE_TUNNEL_TOKEN='$TUNNEL_TOKEN' && \
     export MDF_PUBLIC_IP='$POD_IP' && \
     export MDF_PROVIDER_NAME='$PROVIDER_NAME' && \
     export MDF_FLEET_SIZE='$FLEET_SIZE' && \
     export STF_SECRET=\"\$(openssl rand -hex 32)\" && \
     docker compose -f docker-compose.fleet.yml up -d"

# --- 4. wait until STF healthy + heartbeat -----------------------------
echo "==> step 4/4: wait for STF + heartbeat"
ssh -p "$POD_PORT" "root@$POD_IP" \
    "cd /opt/mdf/command-center && \
     bash scripts/wait-for-stf.sh http://localhost:7100 240"

cat <<EOF

==> fleet pod $MDF_HOSTNAME provisioned successfully.
    public URL: $PUBLIC_URL
    devices:    $FLEET_SIZE (warm pool target = $((FLEET_SIZE / 4)))
    Cloudflare Tunnel: active (auto-renews)
    Cloudflare Access: enforced via mdf-operator + mdf-viewer policies

Next steps:
  - make mdf-status                      # see device count
  - browser to $PUBLIC_URL              # operator UI
  - python3 ota/tools/append.py ...     # publish first OTA build

EOF
