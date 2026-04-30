# MayaOS Device Farm (MDF) — `command-center/`

The orchestrator that runs every MayaOS emulator instance on the
RunPod A6000 pod and exposes them through a unified web UI for
operators.

## Architecture (rev 5.1)

Built on top of [DeviceFarmer/stf](https://github.com/DeviceFarmer/stf)
(formerly OpenSTF). MDF is **STF + 5 plugins** specifically targeted
at containerized emulator instances rather than physical USB devices.

```
                              ┌───────────────────────────┐
                              │   MDF web UI (STF + LESS  │
                              │   reskin, Phase 11)       │
                              └─────────────┬─────────────┘
                                            │  HTTPS via Cloudflare Tunnel
        ┌───────────────────────────────────┼───────────────────────────────────┐
        │                                   ▼                                   │
        │                   ┌──────────────────────────────┐                    │
        │                   │  STF app + auth + websocket  │                    │
        │                   └──────────────────────────────┘                    │
        │                                   │                                   │
        │                          ZeroMQ event bus                             │
        │  ┌────────────────────────────────┼───────────────────────────────┐   │
        │  │                                │                               │   │
        │  ▼                                ▼                               ▼   │
        │ ┌──────────────────────┐  ┌───────────────────────┐  ┌──────────────┐│
        │ │ stf-provider-emulator│  │ MDF plugins (Phase 5) │  │ RethinkDB    ││
        │ │  — N qemu instances  │  │  • mitm               │  │  cluster     ││
        │ │  — adbkit per inst   │  │  • recording          │  │              ││
        │ │  — minicap pre-baked │  │  • ota-channel        │  │              ││
        │ │  — minitouch         │  │  • hvf-preview        │  │              ││
        │ │                      │  │  • warmpool           │  │              ││
        │ └──────────────────────┘  └───────────────────────┘  └──────────────┘│
        │                                                                      │
        └──────────────────────────────────────────────────────────────────────┘
                                            │
                                            ▼
                               ┌────────────────────────┐
                               │   N MayaOS qemu        │
                               │   emulator instances   │
                               │   (sd_phone64_x86_64)  │
                               └────────────────────────┘
```

## STF submodule

The upstream STF source is intentionally **not** vendored in git.
Instead, run once on first clone:

```bash
git submodule add -b master https://github.com/DeviceFarmer/stf command-center/stf
git -C command-center/stf checkout 73d5ad5      # pin: master @ 2026-04-15 (3.7.x)
git submodule update --init --recursive
```

The pin is in `command-center/stf-version` for reference. Update it
deliberately — STF's dataflow contract is stable but the package
layout has shifted between minor versions.

## Layout

```
command-center/
├── README.md              -- you're reading it
├── stf-version            -- pin: DeviceFarmer/stf SHA + tag
├── Dockerfile             -- extends STF's image with Node 18 + our plugins
├── docker-compose.yml     -- single-pod dev stack: rethinkdb + stf + N providers
├── docker-compose.fleet.yml  -- production stack (Cloudflare Tunnel + Access)
├── stf/                   -- git submodule -> DeviceFarmer/stf (NOT in this commit)
├── stf-provider-emulator/ -- our custom provider (Phase 4)
├── mdf-plugin-mitm/       -- per-instance mitmproxy supervisor (Phase 5a)
├── mdf-plugin-recording/  -- multi-track recorder (Phase 5b)
├── mdf-plugin-ota-channel/-- per-device OTA channel pin + UI (Phase 5c)
├── mdf-plugin-hvf-preview/-- Mac handoff (Phase 5d)
├── mdf-plugin-warmpool/   -- warm pool of snapshot-restored instances (Phase 5e)
├── supervisord/           -- supervisord configs for the in-container processes
├── nginx/                 -- nginx config for fronting STF + plugin UIs
├── templates/avd/         -- AVD config.ini / hardware-qemu.ini templates
├── scripts/               -- helper bash scripts (boot, snapshot, recycle)
├── perf/                  -- Phase 4.5 benchmark harness scripts
├── sql/                   -- RethinkDB schema migrations (MDF tables)
└── docs/
    ├── operator-runbook.md  -- (Phase 11) day-to-day operator playbook
    └── plugin-api.md        -- the wire contract between STF and our plugins
```

## Bring-up

```bash
# 1. Add the STF submodule (one-time).
git submodule add -b master https://github.com/DeviceFarmer/stf command-center/stf

# 2. Build the unified container image.
make mdf-build

# 3. Start a one-instance dev stack (rethinkdb + stf + 1 emulator).
make mdf-dev-up

# 4. Open http://localhost:7100 -- you should see one device, click it,
#    drive its UI from the web.
```

## Plugin contract

See [`docs/plugin-api.md`](docs/plugin-api.md). Summary: STF emits
events on a ZeroMQ PUB socket; plugins SUB to the topic(s) they care
about. Plugins also speak the `mdf` REST namespace which gets mounted
under STF's main app at `/mdf/*` for control-plane operations.

## References

- DeviceFarmer/stf: <https://github.com/DeviceFarmer/stf>
- DeviceFarmer/minicap: <https://github.com/DeviceFarmer/minicap>
- DeviceFarmer/minitouch: <https://github.com/DeviceFarmer/minitouch>
- DeviceFarmer/STFService.apk: <https://github.com/DeviceFarmer/STFService.apk>
- Plan §5 — full plugin design + REST + WS contract
