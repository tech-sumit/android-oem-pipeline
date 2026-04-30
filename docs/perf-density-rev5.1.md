# Phase 7 — density baseline (rev 5.1 §6)

This document is the human-readable companion to the raw TSV files
produced by `command-center/perf/density-test.sh`. After every test
run, append a row per tier here so we can track regressions over time.

## Tunings active at every tier

Per rev 5.1 §6.5:

- `vm.nr_hugepages = 12000` (24 GiB hugepages backing qemu memory)
- `vm.swappiness = 10` (almost-never swap)
- KSM enabled (`/sys/kernel/mm/ksm/run = 1`, sleep 1000ms)
- cgroup v2 unified hierarchy with `cpu.weight` per instance
- `qemu -accel tcg,thread=multi,tb-size=512`
- `qemu -drive file=overlay.qcow2,...,readonly=off,backing_file=system.qcow2,...,readonly=on` (RO base + RW overlay)
- `mayaos.prop` boot tunings baked into vendor partition

## Locked rev 5.1 §6 targets

| target | RAM/inst | CPU/inst   | boot p50 | boot p99 | notes        |
|--------|----------|------------|----------|----------|--------------|
|   10   | 1.5 GB   | 4 vCPU     | 30 s     | 45 s     | baseline     |
|  100   | 1.5 GB   | 0.6 vCPU   | 28 s     | 60 s     | KSM, cgroups |
|  250   | 1.5 GB   | 0.25 vCPU  | 35 s     | 90 s     | parallel boot|

## Run history

| date | tier | boot p50 | boot p99 | rss MB | KSM dedup MB | gpu MB | cpu % | notes |
|------|------|----------|----------|--------|--------------|--------|-------|-------|
| TBD  |  10  |    -     |    -     |   -    |      -       |   -    |   -   | initial — pending pod |
| TBD  | 100  |    -     |    -     |   -    |      -       |   -    |   -   | initial — pending pod |
| TBD  | 250  |    -     |    -     |   -    |      -       |   -    |   -   | initial — pending pod |

## Acceptance criteria

A density tier is **accepted** if all of:

- boot p50 within ±10% of locked target
- boot p99 within ±20% of locked target
- per-instance steady-state CPU % within ±15% of target
- KSM dedupe ≥ 30% of pre-KSM RSS at tier-100+
- frame p99 (minicap → operator host) ≤ 200 ms

If any criterion fails, file a regression issue with the run TSV
attached and roll back the most recent tuning change before re-running.

## How to run

```bash
make mdf-build
make mdf-dev-up
cd command-center && bash perf/density-test.sh
```

Then transcribe the TSV row into the table above and commit.

## References

- plan §6, §6.5, §7.5
- `command-center/perf/density-test.sh`
- `command-center/perf/parallel-boot.sh`
