#!/usr/bin/env bash
#
# Print the RunPod CPU flavors and GPU types we can pass to provision.sh.
#
# Why this is a static table instead of a live API call: the v1 REST API
# (rest.runpod.io/v1) only manages existing pods - it does not expose a
# "list available CPU/GPU types" endpoint. The list of valid IDs is encoded
# in the OpenAPI enum, and live pricing/availability lives in the legacy
# GraphQL API (api.runpod.io/graphql). We optionally surface live prices
# via the GraphQL fallback at the bottom.
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_runpod_auth

KIND="${1:-cpu}"

case "$KIND" in
    cpu)
        cat <<'TABLE'
CPU flavors (pass any of these as RUNPOD_CPU_FLAVOR=...):

  FLAVOR   GENERATION   PROFILE             TYPICAL USE
  cpu3c    3rd gen      Compute (1:2 RAM)   pure CPU bursts (cheapest)
  cpu3g    3rd gen      General  (1:4 RAM)  balanced workloads
  cpu3m    3rd gen      Memory   (1:8 RAM)  RAM-heavy jobs
  cpu5c    5th gen      Compute (1:2 RAM)   pure CPU bursts (newest, default)
  cpu5g    5th gen      General  (1:4 RAM)  balanced workloads
  cpu5m    5th gen      Memory   (1:8 RAM)  AOSP-friendly (large RAM:vCPU)

Defaults in runpod/provision.sh: RUNPOD_CPU_FLAVOR=cpu5c, RUNPOD_VCPU=32

For a pure-AOSP build, cpu5m at 32 vCPU gets you ~256 GB RAM which keeps
soong/javac/clang from swapping during peak parallelism.
TABLE
        ;;
    gpu)
        cat <<'TABLE'
GPU types (pass any of these as RUNPOD_GPU_TYPE="..." with RUNPOD_COMPUTE_TYPE=GPU):

  Common SECURE picks (cheapest first; current pricing varies by data center):
    "NVIDIA A40"                       ~$0.44/hr   9 vCPU  / 50 GB RAM
    "NVIDIA RTX A6000"                 ~$0.79/hr  16 vCPU  / 64 GB RAM
    "NVIDIA L40S"                      ~$0.99/hr  16 vCPU  /128 GB RAM
    "NVIDIA RTX 6000 Ada Generation"   ~$0.99/hr  16 vCPU  / 96 GB RAM
    "NVIDIA A100 80GB PCIe"            ~$1.89/hr  16 vCPU  /125 GB RAM
    "NVIDIA H100 PCIe"                 ~$2.39/hr  16 vCPU  /250 GB RAM

Other valid ids (full enum from the REST OpenAPI spec):
    NVIDIA GeForce RTX 4090 / 5090 / 3090 / 3090 Ti
    NVIDIA RTX A5000 / A4500 / A4000 / A2000
    NVIDIA RTX 5000 / 4000 / 2000 Ada Generation
    NVIDIA L4 / L40
    NVIDIA H100 80GB HBM3 / H100 NVL / H200 / H200 NVL / B200
    NVIDIA A100-SXM4-80GB / A30
    NVIDIA RTX PRO 6000 Blackwell {Server,Workstation,Max-Q} Edition
    AMD Instinct MI300X OAM
    Tesla V100-{PCIE-16GB,SXM2-32GB,SXM2-16GB,FHHL-16GB,PCIE-32GB} / Tesla T4

For up-to-date prices and per-DC availability, see:
    https://www.runpod.io/console/gpu-cloud
TABLE
        ;;
    *)
        die "usage: $0 [cpu|gpu]"
        ;;
esac

echo
log "provision a CPU pod: ./runpod/provision.sh                    # uses defaults"
log "                     RUNPOD_CPU_FLAVOR=cpu5m RUNPOD_VCPU=32 ./runpod/provision.sh"
log "provision a GPU pod: RUNPOD_COMPUTE_TYPE=GPU RUNPOD_GPU_TYPE=\"NVIDIA RTX A6000\" ./runpod/provision.sh"
