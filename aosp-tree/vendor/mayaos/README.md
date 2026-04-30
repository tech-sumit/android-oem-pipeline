# `vendor/mayaos/` — vendor partition payload

Everything that ships on the vendor partition for every MayaOS profile
lives here. Per-device differences (the spoof block per device) flow
through this layer's `product.mk`, which the per-device `device/mayaos/
<device>/*.mk` files inherit.

## Layout

```
vendor/mayaos/
├── README.md
├── Android.bp                 -- Soong modules (mayaos-command-exec[.rc])
├── Android.mk                 -- legacy Make include (subdir-makefiles)
├── BoardConfigExtra.mk        -- BUILD_BROKEN_DUP_SYSPROP := true
├── product.mk                 -- the shared inherit point (see plan §3.3)
├── vendorsetup.sh             -- registers MayaOS lunch combos with envsetup
├── mayaos.prop                -- §6.5.6 boot tunings (decision (v))
├── bin/mayaos-command-exec    -- root-owned operator script runner
├── etc/init/mayaos-command-exec.rc -- init service for above
├── manifest_scripts/          -- (Phase 2+) HIDL/AIDL manifest helpers
├── sepolicy/private/          -- mayaos_command_exec.te + friends (Phase 2+)
├── mayaos-patches/            -- AOSP source patches we apply via after-sync
└── rootdir/                   -- files copied into vendor/system at build time
    ├── README.md
    ├── system/etc/security/cacerts/<hash>.0   -- root CAs (Phase 1, 3)
    ├── system/etc/security/otacerts.zip       -- OTA signing cert (Phase 6)
    ├── system/app/STFService/STFService.apk   -- on-device STF agent (Phase 4)
    ├── system/app/MayaOSUpdater/MayaOSUpdater.apk -- OTA app (Phase 6)
    └── data/local/tmp/{minicap,minicap.so,minitouch,minirev}  -- (Phase 4)
```

## Reference

[waydroid/android_vendor_waydroid](https://github.com/waydroid/android_vendor_waydroid).
The Waydroid vendor tree has roughly the same shape — `product.mk`,
`vendorsetup.sh`, `manifest_scripts/`, `sepolicy/`, and `rootdir/` —
each carrying the equivalent role for the Waydroid Wayland container.
