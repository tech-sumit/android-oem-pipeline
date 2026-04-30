# `hardware/mayaos/` — vendor HALs shared across every MayaOS profile

Holds HALs that evolve independently of any single device. Phase 1
seeds the directory; Phase 2 lands the host-injectable sensors HAL
(forked from `waydroid/waydroid-sensors`) under `sensors/`.

## Planned subdirs

| Subdir | Status | Purpose |
|---|---|---|
| `sensors/` | Phase 2 | Host-injectable accelerometer/gyro/proximity/light/barometer (forked from `waydroid/waydroid-sensors`) |
| `audio/` | deferred | Stub HAL routing audio out via a host Unix socket |
| `gatekeeper/` | deferred | Pin/biometric stub for fleet automation |
| `gralloc/` | deferred | gfxstream gralloc passthrough (Phase 4.5 §6.5.2 falls back to upstream) |
| `health/` | deferred | Faked battery for fleet (always 100%, plugged-in) |
| `hwcomposer/` | deferred | gfxstream hwcomposer passthrough |
| `interfaces/` | deferred | shared HIDL/AIDL `.aidl` definitions for the MayaOS HALs |
| `lights/` | deferred | LED stub (no real LEDs in fleet) |
| `memtrack/` | deferred | minimal stub |
| `power/` | deferred | governor passthrough |
| `vibrator/` | deferred | stub (no vibration in fleet) |

## Reference

[waydroid/android_hardware_waydroid](https://github.com/waydroid/android_hardware_waydroid).
The Waydroid hardware tree has the same shape (one subdir per HAL);
we adopt the same convention so backports are mechanical.
