# aosp-tree/ — MayaOS source layered like Waydroid

This directory holds every MayaOS-owned source file that gets spliced
into a freshly synced AOSP working tree. It is laid out the way a real
AOSP vendor lays out their downstream tree — three sibling top-levels
under the AOSP root (`device/`, `hardware/`, `vendor/`) plus an optional
`packages/apps/` for in-tree apps.

The pipeline's `after-sync` hook symlinks each of these into the AOSP
source so the final layout inside the build container looks like:

```
$AOSP_SRC/
├── device/mayaos/                 → aosp-tree/device/mayaos/
├── hardware/mayaos/               → aosp-tree/hardware/mayaos/
├── vendor/mayaos/                 → aosp-tree/vendor/mayaos/
└── packages/apps/MayaOSUpdater/   → aosp-tree/packages/apps/MayaOSUpdater/
```

## Layers

| Layer | Owns | Reference |
|---|---|---|
| `device/mayaos/<device>/` | Per-device .mk files (lunch enumerations, profile-specific overrides like ABI list, OEM tag suffix) | [waydroid/android_device_waydroid_waydroid](https://github.com/waydroid/android_device_waydroid_waydroid) |
| `hardware/mayaos/` | Vendor HALs evolved across all devices: sensors, gralloc, hwcomposer, audio, gatekeeper. Shared by every MayaOS profile. | [waydroid/android_hardware_waydroid](https://github.com/waydroid/android_hardware_waydroid) |
| `vendor/mayaos/` | The vendor partition payload — the shared spoof block, BUILD_BROKEN_DUP_SYSPROP board patch, mayaos.prop, init scripts, sepolicy private rules, vendorsetup.sh lunch combos, and the read-only rootdir trampoline holding pre-baked apks/binaries (STFService.apk, minicap, MayaOSUpdater.apk, root CAs). | [waydroid/android_vendor_waydroid](https://github.com/waydroid/android_vendor_waydroid) |
| `packages/apps/MayaOSUpdater/` | The on-device OTA polling/applying app | [waydroid/android_packages_apps_WaydroidUpdater](https://github.com/waydroid/android_packages_apps_WaydroidUpdater) |

## Why Waydroid-style and not the rev 4 monolithic layout?

Rev 4 had every MayaOS payload (per-device .mk, vendor binaries,
features.xml, CAs) in a single `device-tree/mayaos/galaxy-s26-ultra/`
directory. That worked for one device profile but conflated three
concerns:

1. **Per-device** identity (the spoof block is identical across
   profiles for the same device, so nothing per-device about it).
2. **Per-HAL** evolution (a sensors HAL change for the Pixel 8 Pro
   profile in v2 has zero relationship to the per-device .mk).
3. **Vendor partition** content (binaries, CAs, init scripts: these
   don't belong in `device/<x>/<device>/` because AOSP's
   artifact_path_requirement reserves `system/*` for the GSI; only
   `vendor/*` may install them).

Waydroid's layout solves this by splitting along those exact axes,
which lets us evolve a single HAL across every device, share the spoof
block once, and keep `device/mayaos/<device>/` minimal.

## See also

- `/aosp-tree/vendor/mayaos/README.md` — vendor partition specifics
- `/aosp-tree/hardware/mayaos/README.md` — HAL specifics
- `/aosp-tree/device/mayaos/<device>/README.md` — per-device specifics
- `../docs/waydroid-image-layout.md` — operator runbook
- `../.cursor/plans/mayaos_runpod_fleet_e7c91a52.plan.md` §3 — design
