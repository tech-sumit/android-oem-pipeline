#!/usr/bin/env bash
#
# Rent a RunPod GPU pod sized for the AOSP build, save its id, wait until
# SSH (over public IP) is reachable, then exec a quick health check.
#
# Why GPU and not CPU pods (verified against the live API on 2026-04-29):
#
#   - CPU pods on rest.runpod.io/v1 do NOT receive a public IPv4 even on
#     SECURE cloud. They publish "publicIp": "" and an empty portMappings
#     object, so port 22 is unreachable from the outside.
#   - The fallback "basic SSH" via ssh.runpod.io is a proxy that explicitly
#     does NOT support SCP/SFTP, which breaks rsync (we need rsync for both
#     source sync and artifact fetch).
#   - Only GPU pods get publicIp + portMappings.22, so only GPU pods give us
#     full SSH (= rsync-friendly).
#   - The cheapest viable GPU pod is A6000 1x at ~$0.79/hr (16 vCPU,
#     ~62 GB RAM, ~50 GB ephemeral). That is roughly half the parallelism of
#     a beefy Vast machine but it's still a real AOSP host.
#
# We still optionally support CPU pods (RUNPOD_COMPUTE_TYPE=CPU) for users
# who only need an interactive shell; rsync-based workflows will fail there.
#
# Override defaults via env:
#   RUNPOD_CLOUD_TYPE         SECURE | COMMUNITY        (default SECURE)
#   RUNPOD_COMPUTE_TYPE       GPU | CPU                 (default GPU)
#   RUNPOD_GPU_TYPE           one of the gpuTypeIds     (default NVIDIA RTX A6000)
#   RUNPOD_GPU_COUNT          how many GPUs             (default 1)
#   RUNPOD_CPU_FLAVOR         cpu3c|3g|3m|5c|5g|5m      (only for CPU pods)
#   RUNPOD_VCPU               number of vCPU            (only for CPU pods)
#   RUNPOD_CONTAINER_DISK_GB  ephemeral disk            (default 500)
#   RUNPOD_VOLUME_GB          persistent /workspace     (default 0; see note)
#   RUNPOD_IMAGE              docker image              (default runpod/base:0.6.2-cuda12.4.1)
#   RUNPOD_NAME               pod label                 (default mayaos-aosp-builder)
#   RUNPOD_DATA_CENTER_IDS    optional CSV of dc ids
#   RUNPOD_SSH_KEY            local SSH private key path
#
# Note on RUNPOD_VOLUME_GB: setting volumeInGb on a fresh GPU pod attaches a
# Pod-scoped volume at /workspace. RunPod CPU pods silently drop this field;
# for a persistent CPU /workspace you have to pre-create a network volume
# and pass RUNPOD_NETWORK_VOLUME_ID instead. Default 0 keeps things in the
# 500 GB ephemeral container disk (enough for one full AOSP build).
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_runpod_auth

CLOUD_TYPE="${RUNPOD_CLOUD_TYPE:-SECURE}"
COMPUTE_TYPE="${RUNPOD_COMPUTE_TYPE:-GPU}"
CPU_FLAVOR="${RUNPOD_CPU_FLAVOR:-cpu5c}"
VCPU="${RUNPOD_VCPU:-32}"
GPU_TYPE="${RUNPOD_GPU_TYPE:-NVIDIA RTX A6000}"
GPU_COUNT="${RUNPOD_GPU_COUNT:-1}"
CONTAINER_DISK_GB="${RUNPOD_CONTAINER_DISK_GB:-500}"
VOLUME_GB="${RUNPOD_VOLUME_GB:-0}"
IMAGE="${RUNPOD_IMAGE:-runpod/base:0.6.2-cuda12.4.1}"
NAME="${RUNPOD_NAME:-mayaos-aosp-builder}"
DATA_CENTER_IDS="${RUNPOD_DATA_CENTER_IDS:-}"
NETWORK_VOLUME_ID="${RUNPOD_NETWORK_VOLUME_ID:-}"

SSH_KEY="$(ssh_key_path)"
ensure_ssh_key "$SSH_KEY"
PUBLIC_KEY="$(cat "${SSH_KEY}.pub")"

# Build the JSON payload with jq so all string escaping is safe (the public
# key contains spaces; passing it via printf would break).
BASE_PAYLOAD="$(jq -n \
    --arg cloud  "$CLOUD_TYPE" \
    --arg ctype  "$COMPUTE_TYPE" \
    --arg image  "$IMAGE" \
    --arg name   "$NAME" \
    --arg pubkey "$PUBLIC_KEY" \
    --argjson disk "$CONTAINER_DISK_GB" \
    --argjson vol  "$VOLUME_GB" \
    '{
        cloudType: $cloud,
        computeType: $ctype,
        imageName: $image,
        name: $name,
        containerDiskInGb: $disk,
        volumeInGb: $vol,
        volumeMountPath: "/workspace",
        ports: ["22/tcp"],
        interruptible: false,
        env: { PUBLIC_KEY: $pubkey }
    }')"

if [[ "$COMPUTE_TYPE" == "GPU" ]]; then
    PAYLOAD="$(printf '%s' "$BASE_PAYLOAD" | jq \
        --arg gpu "$GPU_TYPE" \
        --argjson n "$GPU_COUNT" \
        '. + {
            gpuTypeIds: [$gpu],
            gpuCount: $n,
            gpuTypePriority: "availability"
        }')"
else
    PAYLOAD="$(printf '%s' "$BASE_PAYLOAD" | jq \
        --arg flavor "$CPU_FLAVOR" \
        --argjson vcpu "$VCPU" \
        '. + {
            cpuFlavorIds: [$flavor],
            cpuFlavorPriority: "availability",
            vcpuCount: $vcpu
        }')"
fi

if [[ -n "$DATA_CENTER_IDS" ]]; then
    PAYLOAD="$(printf '%s' "$PAYLOAD" | jq --arg dcs "$DATA_CENTER_IDS" \
        '. + { dataCenterIds: ($dcs | split(",")) }')"
fi

if [[ -n "$NETWORK_VOLUME_ID" ]]; then
    PAYLOAD="$(printf '%s' "$PAYLOAD" | jq --arg nvid "$NETWORK_VOLUME_ID" \
        '. + { networkVolumeId: $nvid }')"
fi

log "creating RunPod ${COMPUTE_TYPE} pod (image=${IMAGE}, container=${CONTAINER_DISK_GB}G, volume=${VOLUME_GB}G)"
if [[ "$COMPUTE_TYPE" == "GPU" ]]; then
    log "  cloud=${CLOUD_TYPE} gpu=${GPU_TYPE} count=${GPU_COUNT}"
else
    log "  cloud=${CLOUD_TYPE} flavor=${CPU_FLAVOR} vcpu=${VCPU}"
fi

RESPONSE="$(runpod_post "/pods" "$PAYLOAD")" || die "RunPod POST /pods failed"

POD_ID="$(printf '%s' "$RESPONSE" | jq -r '.id // empty')"
if [[ -z "$POD_ID" ]]; then
    die "RunPod did not return a pod id. Response: $(printf '%s' "$RESPONSE" | head -c 1000)"
fi

mkdir -p "$RUNPOD_DIR"
echo "$POD_ID" > "$POD_FILE"
log "pod id: ${POD_ID} (saved to ${POD_FILE})"

log "waiting for pod to publish a public SSH endpoint (polling every 10s)..."
for i in $(seq 1 60); do
    json="$(runpod_get "/pods/${POD_ID}" 2>/dev/null)" || { sleep 10; continue; }
    status="$(printf '%s' "$json" | jq -r '.desiredStatus // .status // "unknown"')"
    public_ip="$(printf '%s' "$json" | jq -r '.publicIp // empty')"
    public_port="$(printf '%s' "$json" | jq -r '.portMappings["22"] // empty')"
    log "  try ${i}/60: status=${status} ip=${public_ip:-?} port=${public_port:-?}"
    if [[ -n "$public_ip" && -n "$public_port" ]]; then
        break
    fi
    sleep 10
done

if [[ -z "$public_ip" || -z "$public_port" ]]; then
    die "pod ${POD_ID} did not surface an SSH endpoint within 10 minutes (check the RunPod console)"
fi

# Reset the SSH endpoint cache and wait for sshd to actually accept connections.
unset RUNPOD_SSH_CACHE

log "waiting for sshd to accept connections..."
for i in $(seq 1 60); do
    if ssh_into_pod true 2>/dev/null; then
        log "  ssh ok"
        break
    fi
    sleep 5
done

ssh_into_pod 'cat /etc/os-release | grep PRETTY_NAME; echo "vCPU: $(nproc)"; free -g | head -2; df -h /workspace 2>/dev/null || df -h /'

log "pod ${POD_ID} is ready."
log "next steps:"
log "  ./runpod/sync-source.sh        # rsync this repo to the pod"
log "  ./runpod/start-tmux-build.sh   # kick the AOSP build under tmux"
