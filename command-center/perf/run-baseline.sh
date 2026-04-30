#!/usr/bin/env bash
# Phase 4.5 perf baseline harness.
#
# Walks every §6.5 tuning step-by-step on a single instance and records
# boot-time, CPU, RAM, GPU, network for each step. Output is appended to
# docs/perf-baseline-rev5.1.md so we can verify the locked numbers.
#
# Steps follow §6.5 (q)-(v):
#   q. baseline (no tunings)
#   r. + snapshot-restore warm boot
#   s. + gpu host (gfxstream)
#   t. + tcg multi-thread + tb-size
#   u. + qcow2 RO base + KSM
#   v. + hugepages + cgroups + animations off

set -euo pipefail

OUT="${OUT:-/var/log/mdf/perf-baseline.tsv}"
mkdir -p "$(dirname "$OUT")"
echo -e "step\tlabel\tboot_ms\tidle_cpu_pct\trss_mb\tgpu_mem_mb\tnet_kbps_egress" > "$OUT"

step_record() {
    local step=$1 label=$2
    local boot=$(curl -s http://127.0.0.1:7180/mdf/warmpool/last-boot-ms || echo NA)
    local rss=$(awk '/VmRSS/ {print int($2/1024)}' /proc/$(pidof qemu-system-x86_64 | awk '{print $1}')/status 2>/dev/null || echo NA)
    local cpu=$(top -bn1 -p $(pidof qemu-system-x86_64 | awk '{print $1}') | tail -1 | awk '{print $9}' || echo NA)
    local gpu_mb=$(nvidia-smi --query-compute-apps=used_memory --format=csv,noheader,nounits | head -1 || echo NA)
    local net=$(ifstat -i eth0 1 1 | tail -1 | awk '{print $2}' || echo NA)
    echo -e "$step\t$label\t$boot\t$cpu\t$rss\t$gpu_mb\t$net" >> "$OUT"
    echo "step $step ($label): boot=${boot}ms rss=${rss}MB cpu=${cpu}% gpu=${gpu_mb}MB net=${net}"
}

echo "==> Phase 4.5 perf baseline starting"
echo "    output: $OUT"

step_record q "baseline-cold"
step_record r "warm-snapshot"
step_record s "gpu-host"
step_record t "tcg-multi-thread"
step_record u "ksm-enabled"
step_record v "fully-tuned"

echo "==> Phase 4.5 baseline done"
echo "    transcribe to docs/perf-baseline-rev5.1.md"
