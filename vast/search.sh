#!/usr/bin/env bash
#
# Print the top N Vast.ai offers that satisfy the AOSP build profile.
#
# Profile (tunable via env):
#   - >= 32 vCPU            (AOSP 16 builds well above 24 cores; 32 is a sweet spot for $$)
#   - >= 64 GB RAM
#   - >= 1024 GB disk       (~250 GB AOSP source + ~150 GB out/ + 50 GB ccache + headroom)
#   - Ubuntu 22.04 base     (matches our Dockerfile)
#   - >= 100 Mbps net       (repo sync needs bandwidth; <100 Mbps doubles wall time)
#   - On-demand pricing     (interruptible instances will lose your build mid-flight)
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_vastai_auth

CPU_MIN="${CPU_MIN:-24}"
RAM_MIN="${RAM_MIN:-64}"
DISK_MIN="${DISK_MIN:-1024}"
NET_MIN="${NET_MIN:-100}"
TOP_N="${TOP_N:-5}"
DPH_MAX="${DPH_MAX:-0.80}"

log "searching Vast.ai (>=${CPU_MIN} effective vCPU, >=${RAM_MIN}G RAM, >=${DISK_MIN}G disk, <=\$${DPH_MAX}/hr, top ${TOP_N})"

# vastai's `cpu_cores` is the HOST's physical cores; `cpu_cores_effective` is
# the slice actually allocated to your container. Always filter on effective
# (a host with 80 cores might allocate you only 10).
#
# rentable=true       skips machines currently allocated to someone else
# verified=true       skips unverified hosts (no SLA, prone to disconnects)
# cuda_max_good>=0    no GPU requirement (we only need CPU)
QUERY="rentable=true verified=true \
       cpu_cores_effective>=${CPU_MIN} \
       cpu_ram>=${RAM_MIN} \
       disk_space>=${DISK_MIN} \
       inet_down>=${NET_MIN} \
       inet_up>=${NET_MIN} \
       dph_total<=${DPH_MAX} \
       cuda_max_good>=0"

# NOTE: We pass the python script via `-c` (not stdin) so the JSON stream from
# vastai stays piped into sys.stdin. Earlier versions used `python3 - <<'PY'`
# which silently dropped the pipe (shellcheck SC2259).
vastai search offers "$QUERY" \
    --order 'dph_total' \
    --limit "$TOP_N" \
    --raw 2>/dev/null \
| python3 -c "$(cat <<'PY'
import json, sys

top_n = int(sys.argv[1])
offers = json.load(sys.stdin)
if not offers:
    print("no offers match. Loosen DPH_MAX or CPU_MIN.", file=sys.stderr)
    sys.exit(1)

cols = ("id", "$/hr", "vCPU", "RAM(G)", "Disk(G)", "Down", "Up", "host")
print(f"{cols[0]:>9}  {cols[1]:>5}  {cols[2]:>5}  {cols[3]:>6}  {cols[4]:>7}  {cols[5]:>6}  {cols[6]:>6}  {cols[7]}")
print("-" * 90)
for o in offers[:top_n]:
    print(f"{o['id']:>9}  "
          f"{o['dph_total']:>5.3f}  "
          f"{int(o['cpu_cores']):>5}  "
          f"{int(o['cpu_ram']):>6}  "
          f"{int(o['disk_space']):>7}  "
          f"{int(o.get('inet_down', 0)):>6}  "
          f"{int(o.get('inet_up', 0)):>6}  "
          f"{o.get('host_id','?')}")

print()
print("Provision with: ./vast/provision.sh <id>")
PY
)" "$TOP_N"
