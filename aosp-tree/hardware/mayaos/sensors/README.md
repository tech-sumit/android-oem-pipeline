# `hardware/mayaos/sensors/` — host-injectable sensors HAL

Modeled on [`waydroid/waydroid-sensors`](https://github.com/waydroid/waydroid-sensors)
but adapted for the qemu+ADB transport that the MayaOS fleet uses
(Waydroid uses Wayland + LXC abstract sockets).

## What it does

Implements `android.hardware.sensors-V3` AIDL on the guest. Instead of
pulling sensor readings from real hardware (which the emulator doesn't
have), the HAL connects to a Unix socket on the host (forwarded into
the guest as an abstract socket via ADB reverse) and pulls a stream of
SensorEvents from there.

Supported sensor types (one entry per Android sensor type ID):

| Type | Sensor name | Min delay | Used by |
|---|---|---|---|
| `1` ACCELEROMETER | MayaOS Accelerometer | 5 ms (200 Hz) | replay tests, screen rotation |
| `4` GYROSCOPE | MayaOS Gyroscope | 5 ms (200 Hz) | game tests, AR tests |
| `5` LIGHT | MayaOS Ambient Light | 200 ms (5 Hz) | autobrightness behavior |
| `6` PRESSURE | MayaOS Barometer | 200 ms (5 Hz) | altimeter apps |
| `8` PROXIMITY | MayaOS Proximity | 200 ms (5 Hz) | call screen behavior |
| `11` ROTATION_VECTOR | MayaOS Rotation Vector | 5 ms | composite-orientation apps |
| `13` AMBIENT_TEMPERATURE | MayaOS Ambient Temp | 1 s (1 Hz) | weather apps |
| `19` STEP_COUNTER | MayaOS Step Counter | 1 s (1 Hz) | fitness apps |
| `20` STEP_DETECTOR | MayaOS Step Detector | event-based | fitness apps |

## Files

```
aidl/
  Android.bp                        -- aidl_interface + cc_binary modules
  default/
    Sensors.cpp                     -- ISensors AIDL implementation
    Sensors.h                       -- header
    SensorThread.cpp                -- background thread that reads from
    SensorThread.h                     the host socket and emits events
    HostTransport.cpp               -- abstract Unix socket client
    HostTransport.h
    main.cpp                        -- service entry point
    sensors.mayaos.rc               -- init.rc to start the service
host-injector/
  README.md                         -- runbook: how to inject events
  inject.py                         -- CLI: inject one-shot event
  replay.py                         -- CLI: replay a recorded session
  protocol.md                       -- wire protocol spec
vintf/
  android.hardware.sensors-service.mayaos.xml -- VINTF declaration
```

## Wire protocol

Length-prefixed binary frames over an abstract Unix socket
(`@mayaos.sensors`). Each frame is 32 bytes:

```
struct SensorEventFrame {
    uint8_t  sensor_type;       // see table above
    uint8_t  reserved;          // == 0
    uint16_t flags;             // bit 0: lastInBatch
    int32_t  payload_len;       // for variable-length sensors; usually 0
    int64_t  timestamp_ns;      // monotonic clock; 0 = HAL clamps to now()
    float    v[4];              // up to 4 channels (vector + scalar)
};
```

The host injector (`command-center/mdf-plugin-recording/sensors.js`,
implemented in Phase 5) opens the socket, sends one frame per sensor
per cycle. The HAL forwards each frame to the appropriate sensor's
configured client at the configured rate; if no frame arrives within
`max_delay_us`, the HAL emits the last-known value (so the sensor never
goes "stuck").

## Service registration

Registered as `android.hardware.sensors.ISensors/default`. The VINTF
fragment in `vintf/` declares the interface so the framework discovers
us instead of the goldfish stub HAL on the emulator boards.

## Reference

- [waydroid/waydroid-sensors](https://github.com/waydroid/waydroid-sensors) — original Waydroid implementation
- [android.hardware.sensors-V3 AIDL](https://cs.android.com/android/platform/superproject/main/+/main:hardware/interfaces/sensors/aidl/) — upstream AIDL definitions
- Plan §6 — recording/replay design
