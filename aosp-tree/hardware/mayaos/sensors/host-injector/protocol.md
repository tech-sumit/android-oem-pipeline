# `mayaos.sensors` host wire protocol

Length: every frame is exactly 32 bytes, little-endian, packed.

## Frame layout

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 1 | `sensor_type` | Android `SensorType.aidl` enum value (1=ACCEL, 4=GYRO, 5=LIGHT, 6=PRESSURE, 8=PROX, 11=ROT_VEC, 13=AMBIENT_TEMP, 19=STEP_COUNTER, 20=STEP_DETECT) |
| 1 | 1 | `reserved` | must be 0 |
| 2 | 2 | `flags` | bit 0: `wakeUpEvent`; bit 1: `lastInBatch`; rest: reserved |
| 4 | 4 | `payload_len` | `int32_t`; for variable-length sensors. Currently always 0. |
| 8 | 8 | `timestamp_ns` | `int64_t`, monotonic. `0` means "let the HAL stamp `now()`". |
| 16 | 16 | `v[4]` | 4 × IEEE 754 single-precision float, channel-major. See per-sensor table below. |

## Per-sensor channel meaning

| Type | `v[0]` | `v[1]` | `v[2]` | `v[3]` |
|---|---|---|---|---|
| ACCEL (1) | x m/s² | y m/s² | z m/s² | unused |
| GYRO (4) | x rad/s | y rad/s | z rad/s | unused |
| LIGHT (5) | lux | unused | unused | unused |
| PRESSURE (6) | hPa | unused | unused | unused |
| PROXIMITY (8) | cm | unused | unused | unused |
| ROT_VEC (11) | x | y | z | scalar |
| AMBIENT_TEMP (13) | °C | unused | unused | unused |
| STEP_COUNTER (19) | total steps since boot | unused | unused | unused |
| STEP_DETECTOR (20) | always 1.0 | unused | unused | unused |

## Transport

Linux abstract Unix socket `@mayaos.sensors`. The host (running outside
the guest) is the server; the in-guest HAL is the client. The host
forwards the socket into the guest via:

```
adb reverse localabstract:mayaos.sensors localabstract:mayaos.sensors
```

(`stf-provider-emulator` does this on every emulator boot.) On
disconnect the HAL retries with exponential backoff (100ms → 5s).

## Backpressure

The host should keep its send rate ≤ what the framework reads. The
HAL's FMQ is sized to ~16 events; on overflow the HAL drops with a
`logd` warning. Replay sources (see `mdf-plugin-recording`) read events
back at the recorded timestamps, so the rate matches the original.

## Operator CLI

- `inject.py SENSOR --val A,B,C,D` — one-shot.
- `replay.py PATH/TO/recording.jsonl` — playback at recorded timing.

See `inject.py --help` for full usage.
