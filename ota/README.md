# MayaOS OTA channel

Modeled after [waydroid/OTA](https://github.com/waydroid/OTA) — a flat
JSON index hosted on Cloudflare Pages, with payload artifacts in R2.

## Layout

```
ota/
├── README.md                       you're reading it
├── tools/
│   ├── append.py                   append a new build to a channel
│   └── promote.py                  promote a build between channels
├── templates/
│   ├── channels.json.tmpl          base index
│   └── channel-stable.json.tmpl    per-channel build manifest
└── site/
    ├── _headers                    Cloudflare Pages headers (cache, MIME)
    ├── _redirects                  Cloudflare Pages redirect rules
    └── index.html                  human-friendly OTA browser
```

After every passing build (Phase 0 + Phase 6 GH Action),
`ota/tools/append.py` produces / updates these objects:

```
ota/site/channels.json
ota/site/<channel>.json
```

…then commits `ota/site/` to a separate branch (`gh-pages-ota`) which
Cloudflare Pages serves at `https://ota.mayaos.dev`.

## Channel JSON contract

`channels.json`:

```json
{
  "v": 1,
  "generatedAt": "2026-04-30T20:30:00Z",
  "channels": {
    "stable":  { "url": "https://ota.mayaos.dev/stable.json",  "latest": "16-r5" },
    "canary":  { "url": "https://ota.mayaos.dev/canary.json",  "latest": "16-r6-rc1" },
    "dev":     { "url": "https://ota.mayaos.dev/dev.json",     "latest": "20260430.1900" }
  }
}
```

`stable.json` (per-channel):

```json
{
  "v": 1,
  "channel": "stable",
  "builds": [
    {
      "id":        "16-r5",
      "ts":        1729900000,
      "profile":   "galaxy-s26-ultra-emulator-x86",
      "fingerprint": "samsung/SM-S948B/galaxy-s26-ultra:16/AP3A.250516.001.A1/...",
      "system_img":   { "url": "https://r2.../system-16-r5.qcow2",   "sha256": "abc..." },
      "vendor_img":   { "url": "https://r2.../vendor-16-r5.qcow2",   "sha256": "def..." },
      "boot_img":     { "url": "https://r2.../boot-16-r5.img",       "sha256": "012..." },
      "size_bytes":   2_400_000_000,
      "notes":        "perf tuning baseline rev 5.1"
    }
  ]
}
```

## Where the device picks this up

`MayaOSUpdater.apk` (system app, baked into vendor partition) hosts a
foreground service that:

1. Reads `ro.mayaos.channel` (default: `stable`) from system props.
2. Fetches `https://ota.mayaos.dev/<channel>.json`.
3. Compares `builds[0].id` with current `ro.mayaos.version`; if newer,
   downloads the system + vendor + boot images, verifies sha256, and
   schedules an A/B install (handed to AOSP `update_engine` which is
   already part of the standard build).
4. Reports back to MDF (`POST /mdf/ota-channel/devices/:serial/attempt`)
   so the operator dashboard reflects per-device install status.

For our managed pods, MDF can also push a check via
`POST /mdf/ota-channel/devices/:serial/check-now` (Phase 5c plugin)
which fires the foreground service immediately rather than waiting
for the periodic poll.

## CI hookup

`.github/workflows/ota.yml` runs after a successful `make build`:

1. `python ota/tools/append.py --channel canary --artifact <out/...>`
2. Commit `ota/site/` to `gh-pages-ota` branch
3. Cloudflare Pages auto-deploys

## Manual promotion

```bash
python ota/tools/promote.py --from canary --to stable --build 16-r6-rc1
git -C ota/site commit -am "promote 16-r6-rc1 stable"
git -C ota/site push origin gh-pages-ota
```

## References

- waydroid/OTA: <https://github.com/waydroid/OTA>
- waydroid/android_packages_apps_WaydroidUpdater
- AOSP A/B updates: <https://source.android.com/docs/core/ota/ab>
- plan §6
