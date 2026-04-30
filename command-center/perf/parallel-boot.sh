#!/usr/bin/env bash
# Parallel-boot N instances and measure cold-boot wall-clock.
#
# Cold-boots N qemu instances in parallel batches of `BATCH` (default 10)
# and records wall-clock for each instance to stdout + a TSV. Used in
# Phase 7 density testing to find the right batch size where
# `boot wall-clock <= 60s` for tier-100 and `<= 90s` for tier-250.
#
# Usage:
#   N=100 BATCH=10 ./parallel-boot.sh
#
# Background: spawning all N at once thrashes IO and ksmd; spawning one
# at a time wastes CPU. Empirically (rev 5.1 §6) batches of 10 hit the
# sweet spot on an A6000 pod.

set -euo pipefail

N="${N:-10}"
BATCH="${BATCH:-10}"
OUT="${OUT:-/tmp/parallel-boot.tsv}"
echo -e "instance\tboot_ms" > "$OUT"

boot_one() {
    local i=$1
    local t0=$(date +%s%3N)
    docker compose -f docker-compose.yml exec mdf curl -sf -XPOST \
        http://127.0.0.1:7180/mdf/warmpool/restore \
        -H 'Content-Type: application/json' \
        -d "{\"serial\":\"emulator-$((5554 + i*2))\",\"name\":\"warm\"}" >/dev/null
    local t1=$(date +%s%3N)
    echo -e "emulator-$((5554 + i*2))\t$((t1 - t0))" >> "$OUT"
}

echo "==> parallel-boot N=$N BATCH=$BATCH"
for ((start=0; start<N; start+=BATCH)); do
    end=$((start + BATCH))
    [ $end -gt $N ] && end=$N
    pids=()
    for ((i=start; i<end; i++)); do
        boot_one $i &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done
    echo "    batch [$start, $end) complete"
done

echo "==> done -- TSV at $OUT"
sort -k2n "$OUT" | tail -5
