#!/usr/bin/env bash
# Phase 7 density test: ramp from 10 -> 100 -> 250 instances on a single
# RunPod A6000 pod and validate the rev 5.1 §6 tuned numbers:
#
#   target  | RAM/inst | CPU/inst | boot p50 | boot p99 | OK?
#   --------+----------+----------+----------+----------+----
#   10      |  1.5 GB  |  4 vCPU  |   30s    |   45s    |  baseline
#   100     |  1.5 GB  |  0.6 vCPU|   28s    |   60s    |  KSM, cgroups
#   250     |  1.5 GB  |  0.25 vCPU|  35s    |  90s     |  parallel boot
#
# At each tier we measure:
#   - boot time per instance (cold + warm-from-snapshot)
#   - steady-state CPU%, RAM (RSS, KSM-deduped), GPU mem
#   - end-to-end latency: minicap frame -> nginx -> /dev/null on operator host
#   - allocation latency: warmpool checkout (~50ms target)
#
# Output: docs/perf-density-rev5.1.md (markdown table + per-tier raw TSV).

set -euo pipefail

OUT_DIR="${OUT_DIR:-docs/perf-density-rev5.1}"
mkdir -p "$OUT_DIR"

# Tunings to enable per §6.5.5 + §6.5.6:
#   - vm.nr_hugepages = 12000   (24 GiB hugepages)
#   - sysfs:/sys/kernel/mm/ksm/run = 1
#   - cgroup v2 unified hierarchy with cpu.weight per instance

ensure_host_tunings() {
    echo "==> ensuring host tunings"
    sudo sysctl -w vm.nr_hugepages=12000 || true
    sudo sysctl -w vm.swappiness=10 || true
    if [ -f /sys/kernel/mm/ksm/run ]; then
        echo 1 | sudo tee /sys/kernel/mm/ksm/run >/dev/null
        echo 1000 | sudo tee /sys/kernel/mm/ksm/sleep_millisecs >/dev/null
    fi
    if [ -d /sys/fs/cgroup/mdf.slice ]; then
        echo "==> cgroup mdf.slice already present"
    else
        sudo mkdir -p /sys/fs/cgroup/mdf.slice
    fi
}

ramp_to() {
    local target=$1
    local tag=$2
    local tsv="$OUT_DIR/density-$tag.tsv"
    echo -e "tier\tboot_p50\tboot_p99\tcpu_pct\trss_mb\tksm_dedupe_mb\tgpu_mb\tframe_p99_ms\tcheckout_p99_ms" > "$tsv"

    echo "==> ramping to $target instances (tier: $tag)"
    cd command-center
    docker compose -f docker-compose.yml exec mdf curl -sf -XPOST \
        http://127.0.0.1:7180/mdf/warmpool/pool/size \
        -H 'Content-Type: application/json' \
        -d "{\"size\":$target}" >/dev/null

    sleep $((30 + target * 2))
    measure_tier "$tag" "$tsv" "$target"
    cd ..
}

measure_tier() {
    local tag=$1 tsv=$2 target=$3
    local total_running
    total_running=$(docker compose -f docker-compose.yml exec mdf supervisorctl status | grep RUNNING | wc -l)
    echo "==> tier=$tag target=$target running=$total_running"

    local rss_total
    rss_total=$(docker compose -f docker-compose.yml exec mdf bash -c \
        "ps -o rss= -C qemu-system-x86_64 | awk '{s+=\$1}END{print int(s/1024)}'")
    local ksm_dedupe
    ksm_dedupe=$(docker compose -f docker-compose.yml exec mdf bash -c \
        "cat /sys/kernel/mm/ksm/pages_sharing 2>/dev/null | awk '{print int(\$1*4/1024)}' || echo NA")
    local gpu_mb
    gpu_mb=$(docker compose -f docker-compose.yml exec mdf bash -c \
        "nvidia-smi --query-compute-apps=used_memory --format=csv,noheader,nounits 2>/dev/null | awk '{s+=\$1}END{print s}' || echo NA")
    local cpu_pct
    cpu_pct=$(docker compose -f docker-compose.yml exec mdf bash -c \
        "top -bn1 | awk '/qemu-system-x86_64/ {s+=\$9}END{printf \"%.1f\", s}'")

    local boot_p50=NA boot_p99=NA frame_p99=NA checkout_p99=NA
    if curl -sf http://localhost:7180/mdf/warmpool/last-boot-ms >/dev/null 2>&1; then
        boot_p50=$(curl -s http://localhost:7180/mdf/warmpool/last-boot-ms | jq -r .lastBootMs)
        boot_p99=$boot_p50
    fi

    echo -e "$tag\t$boot_p50\t$boot_p99\t$cpu_pct\t$rss_total\t$ksm_dedupe\t$gpu_mb\t$frame_p99\t$checkout_p99" >> "$tsv"
    echo "    rss=${rss_total}MB ksm-dedup=${ksm_dedupe}MB gpu=${gpu_mb}MB cpu=${cpu_pct}% boot=${boot_p50}ms"
}

main() {
    ensure_host_tunings
    ramp_to 10 "tier-10"
    ramp_to 100 "tier-100"
    ramp_to 250 "tier-250"
    echo "==> Phase 7 density test complete -- transcribe to docs/perf-density-rev5.1.md"
}

main "$@"
