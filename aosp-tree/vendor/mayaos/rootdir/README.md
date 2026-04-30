# `vendor/mayaos/rootdir/` — pre-baked vendor partition payload

Files in this tree get copied into the vendor partition at the matching
on-device path during AOSP build. Used for content that the orchestrator
needs to read from the device without having to ADB-push it after boot
(zero install-time latency, zero PID race).

## Subdirs

| Subdir | Purpose | Phase |
|---|---|---|
| `system/etc/security/cacerts/` | MayaOS root CAs trusted by the system store | 1 (pre-existing) + 3 (MCC root CA) |
| `system/etc/security/otacerts.zip` | OTA package signing cert (`ota-signing-key.x509.pem`) | 6 |
| `system/app/STFService/STFService.apk` | DeviceFarmer's on-device monitor + remote action service | 4 |
| `system/app/MayaOSUpdater/MayaOSUpdater.apk` | On-device OTA polling/applying app | 6 |
| `data/local/tmp/minicap` | DeviceFarmer screen streamer (binary) | 4 |
| `data/local/tmp/minicap.so` | minicap helper shared lib | 4 |
| `data/local/tmp/minitouch` | DeviceFarmer multi-touch event injector | 4 |
| `data/local/tmp/minirev` | DeviceFarmer reverse-port-forwarder | 4 |

## How it ships

`vendor/mayaos/product.mk` walks each PRODUCT_COPY_FILES entry under
this tree and copies it into the matching destination on the vendor
partition (or system partition for `system/...` paths, with
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST whitelisting).

## Why pre-bake instead of ADB-push?

STF normally pushes minicap / minitouch / STFService at runtime when a
new device shows up. For our cold-boot fleet that adds ~30s per device
to first-registration time. Pre-baking those binaries cuts registration
to <2s and removes a class of "ADB push race" failures during fleet
ramp-up. See plan §3 (decision (m)).
