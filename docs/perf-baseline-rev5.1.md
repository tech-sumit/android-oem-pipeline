# Phase 4.5 — single-instance perf baseline (rev 5.1 §6.5)

This document captures the **actual measured numbers** for the
6 stepped tunings (q)-(v) locked in plan rev 5.1 §6.5. Run the
benchmark on the same A6000 pod that hosts the Phase 4 single-instance
proof — that way we attribute every change to one variable at a time.

## Procedure

1. Bring up the single-instance dev stack:
   ```bash
   make mdf-build && make mdf-dev-up
   bash command-center/scripts/wait-for-stf.sh
   ```
2. For each tier (q)-(v), apply ONE additional tuning, restart the
   instance, and run `make mdf-perf-baseline`.
3. Append the output row to the table below.

## Tunings (each row adds the new tuning ON TOP of the previous)

| step | tuning enabled                                  | qemu / kernel knob applied                        |
|------|--------------------------------------------------|---------------------------------------------------|
| q    | baseline (no MayaOS tunings)                    | none beyond stock qemu                            |
| r    | + warm snapshot-restore                         | `-loadvm warm` via warmpool                       |
| s    | + GPU host (gfxstream + virtio-gpu-gl)          | `-gpu host -display vnc=0,gl=on`                  |
| t    | + multi-thread TCG + tb-size                    | `-accel tcg,thread=multi,tb-size=512`             |
| u    | + qcow2 RO base + KSM                           | RO base + RW overlay; ksm.run=1                   |
| v    | + hugepages + cgroups + animations off          | mem-prealloc; mayaos.prop                         |

## Locked targets (§6.5)

| step | boot p50 | boot p99 | RSS (MB) | KSM dedup (MB) | GPU MB | net kbps |
|------|----------|----------|----------|----------------|--------|----------|
| q    | 60s      | 120s     | 2200     |    0           |   0    |    -     |
| r    |  3s      |   6s     | 2200     |    0           |   0    |    -     |
| s    |  3s      |   6s     | 2200     |    0           |  900   |    -     |
| t    |  3s      |   6s     | 2200     |    0           |  900   |    -     |
| u    |  3s      |   6s     | 1500     |  600           |  900   |    -     |
| v    |  3s      |   6s     | 1500     |  600           |  900   |    -     |

## Measured (fill in from `command-center/perf/run-baseline.sh` output)

| run date           | step | boot p50 ms | boot p99 ms | RSS MB | KSM dedup MB | GPU MB | net kbps | within target? | notes |
|--------------------|------|-------------|-------------|--------|--------------|--------|----------|----------------|-------|
| TBD pod-eu-de-0    | q    |     -       |     -       |   -    |     -        |   -    |    -     | -              | initial |
| TBD pod-eu-de-0    | r    |     -       |     -       |   -    |     -        |   -    |    -     | -              | initial |
| TBD pod-eu-de-0    | s    |     -       |     -       |   -    |     -        |   -    |    -     | -              | initial |
| TBD pod-eu-de-0    | t    |     -       |     -       |   -    |     -        |   -    |    -     | -              | initial |
| TBD pod-eu-de-0    | u    |     -       |     -       |   -    |     -        |   -    |    -     | -              | initial |
| TBD pod-eu-de-0    | v    |     -       |     -       |   -    |     -        |   -    |    -     | -              | initial |

## How to run a row

```bash
make mdf-build
make mdf-dev-up
# edit command-center/templates/qemu/<step>.args (one canonical args
# file per tuning step) and restart the instance:
make mdf-restore
make mdf-perf-baseline
# append the printed row to the table above and commit
```

## Acceptance

A tuning step is accepted if all of:

- boot p50 within ±15% of locked target
- boot p99 within ±25% of locked target
- RSS within ±15% of locked target
- KSM dedup within ±20% of locked target (for steps u, v)

If any is off, file a regression and roll back the most recent
tuning before re-running.

## See also

- plan §6.5 (q)-(v)                      — locked decisions
- `command-center/perf/run-baseline.sh`  — bench harness
- `command-center/perf/density-test.sh`  — Phase 7 multi-instance
- `aosp-tree/vendor/mayaos/mayaos.prop`  — guest-side tunings (step v)
- `command-center/stf-provider-emulator/lib/qemu.js` — qemu argv assembly
