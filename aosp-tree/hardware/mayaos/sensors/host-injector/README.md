# `mayaos.sensors` host injector

CLI tools for poking events into a MayaOS guest's sensors HAL from the
host. Both scripts open the abstract Unix socket `@mayaos.sensors`,
which `stf-provider-emulator` forwards into the guest with:

```
adb reverse localabstract:mayaos.sensors localabstract:mayaos.sensors
```

## Files

- `inject.py` — one-shot CLI for ad-hoc events (great for `make` recipes
  and operator runbooks).
- `replay.py` — paced replay of a JSONL recording produced by
  `mdf-plugin-recording`'s sensor track.
- `protocol.md` — wire format reference (32-byte packed binary frames).

## Quick examples

```bash
# Pretend the device just got picked up (proximity goes from 0 to 5cm).
./inject.py proximity --val 0
sleep 0.5
./inject.py proximity --val 5

# Pretend the user took 100 steps in 10s.
for i in $(seq 1 100); do
    ./inject.py step_detect --val 1
    sleep 0.1
done
./inject.py step_counter --val 100

# Replay a previously-recorded session at 2x.
./replay.py recordings/2026-04-30T12-00-00.sensors.jsonl --rate 2.0
```

## Recording format

```jsonl
{"t": 1714512000123456789, "sensor": "accel", "v": [0.0, 0.1, 9.8]}
{"t": 1714512000128456789, "sensor": "accel", "v": [0.0, 0.1, 9.8]}
{"t": 1714512000133456789, "sensor": "gyro",  "v": [0.0, 0.0, 0.0]}
```

`t` is `clock_gettime(CLOCK_MONOTONIC, ...)` in nanoseconds at record
time. Replay computes the per-event sleep relative to the first `t` so
the temporal pattern is preserved.
