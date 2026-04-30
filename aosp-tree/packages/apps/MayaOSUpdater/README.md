# MayaOSUpdater

System app baked into the vendor partition. Polls
`https://ota.mayaos.dev/<channel>.json` and hands the payload to
AOSP's `update_engine` for an A/B install.

Modeled after
[waydroid/android_packages_apps_WaydroidUpdater](https://github.com/waydroid/android_packages_apps_WaydroidUpdater).

## Pieces

| File                          | Purpose                                  |
|-------------------------------|------------------------------------------|
| `MainActivity.java`           | Operator UI (channel + version + Check now) |
| `UpdateCheckService.java`     | Foreground service that fetches the channel JSON |
| `UpdateEngineBridge.java`     | Wraps `android.os.UpdateEngine` for A/B install |
| `BootReceiver.java`           | Kicks an update check on every boot      |
| `privapp-permissions-*.xml`   | System-app permission allowlist          |
| `default-permissions-*.xml`   | Auto-grant runtime permissions on first boot |

## Wired into the build

Listed in `aosp-tree/vendor/mayaos/product.mk`:

```make
PRODUCT_PACKAGES += \
    MayaOSUpdater \
    privapp-permissions-mayaos-updater.xml \
    default-permissions-mayaos-updater.xml
```

## How MDF triggers a check

MDF's `mdf-plugin-ota-channel` (Phase 5c) issues:

```
adb shell am start-foreground-service \
  -n dev.mayaos.updater/.UpdateCheckService --es channel canary
```

The service runs immediately; periodic `WorkManager` jobs continue
to run every 6h independently.

## Reporting back

After the install attempt is queued, the service POSTs to
`${ro.mayaos.mdf_endpoint}/mdf/ota-channel/devices/local/attempt`
so MDF reflects per-device install status. The endpoint is read from
a system property; MDF sets it via `setprop` over adb on first boot
of every fleet instance.
