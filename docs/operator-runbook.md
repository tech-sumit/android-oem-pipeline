# MDF operator runbook

A practical playbook for running the MayaOS Device Farm. Aimed at:

- **Operator** — daily user of the web UI.
- **On-call** — paged when an alert fires.
- **Owner** (sumit) — capacity planning, OTA promotion decisions.

## TL;DR commands

```bash
make mdf-status                              # see all pods + device counts
make mdf-dev-up                              # local 1-instance dev stack
make mdf-fleet-up                            # production stack on a single pod
make mdf-provision                           # full provisioning of a fresh pod
make mdf-destroy POD_NAME=mdf-pod-eu-de-0    # safe teardown (R2-snapshot first)
make mdf-perf-baseline                       # Phase 4.5 perf benchmark
make mdf-perf-density                        # Phase 7 density benchmark
make mdf-ha-setup POD0_HOST=... POD1_HOST=...  # 2-pod HA bring-up
make mdf-ha-drill POD0_HOST=... POD1_HOST=...  # failover smoke test
make mdf-rotate-ca                           # rotate the MDF root CA
make mdf-observability-push                  # push dashboards + alerts
make mdf-ota-append CHANNEL=canary BUILD_ID=... ARTIFACT_DIR=...
make mdf-ota-promote SRC=canary DST=stable BUILD=...
```

## Daily operator flow

1. Open `https://mdf.mayaos.dev` (Cloudflare Access prompts for OIDC).
2. The fleet grid shows every device colored by status:
   `ready` (teal), `busy` (purple), `offline` (gray).
3. Click a device → "Control" tab to drive its UI live.
4. Right rail tabs:
   - **MITM** — click "Intercept On"; flows stream live; click any
     flow → modify request/response → "Replay".
   - **Recording** — "Start Session" cuts a multi-track recording
     (screen + adb log + sensors + mitm); "Stop" uploads to R2.
   - **OTA** — change channel pin per-device; "Check now" triggers
     an immediate update from the pinned channel.
   - **HVF Preview** — "Snapshot to Mac" produces a download link
     + `make hvf-attach IMG=...` command for the developer's Mac.
5. System actions menu (top right): restart / shutdown / factory
   reset / install-apk / uninstall-app.

## On-call: alert response

| alert                            | first action                                              |
|----------------------------------|-----------------------------------------------------------|
| `MDFInstanceCountDegraded`       | `make mdf-pod-status` on the pod, look for crash loop     |
| `MDFColdBootP99Spike`            | check `mdf-fleet` dashboard "boot" panel; check KSM       |
| `MDFCheckoutLatencySpike`        | `curl /mdf/warmpool/pool` -- pool starved? bump pool size |
| `MDFMitmFlowStall`               | `adb shell iptables -t nat -L OUTPUT` -- rule lost?       |
| `MDFRecordingR2Lag`              | check Cloudflare R2 status + `R2_*` env vars              |
| `MDFOTAChannel*Stale`            | check `.github/workflows/ota.yml` runs                    |
| `MDFKSMDedupeLow`                | `cat /sys/kernel/mm/ksm/run` -- ksmd dead?                |
| `MDFCloudflareTunnelDown`        | `docker logs mdf-tunnel` + Cloudflare status              |
| `MDFRethinkDBReplicaLag`         | `docker logs rethink` + `rethinkdb-cli` for replica state |
| `MDFDiskPressure`                | `du -sh /var/lib/mdf/* | sort -h | tail` + LRU evict      |
| `MDFNVENCSaturation`             | reduce focused-stream count or fall back to software h264 |
| `MDFAccessDenySpike`             | check Cloudflare Access logs for the offending principal  |

## Capacity planning

- Each pod (A6000) hosts up to ~80 instances tuned (rev 5.1 §6).
- $0.79/hr per pod ≈ $570/month sustained.
- 2 pods (HA) ≈ $1,140/month, 0% data loss tolerance.
- Adding a 3rd pod: same `make mdf-provision` again with new HOST.
- RethinkDB cluster auto-includes new members via `--join`.

## OTA promotion checklist

Before promoting `canary` → `stable`:

1. `make mdf-status` — fleet healthy?
2. Check `mdf-fleet` dashboard — boot p99 + KSM dedupe both green?
3. Pin a few production-shape devices to `canary`, run smoke tests:
   ```bash
   python3 -m mayaos_devicefarm.smoke --channel canary --device emulator-5554
   ```
4. `make mdf-ota-promote SRC=canary DST=stable BUILD=<id>`
5. Watch `MDFOTAChannelStable_Stale` — should auto-resolve.
6. Trickle deploy: `mdf-plugin-ota-channel` honors `rollout_pct` field
   in the channel doc; bump 1% → 10% → 100% over 24h.

## Quarterly maintenance

- Rotate MDF root CA (`make mdf-rotate-ca`); 90-day deprecation window.
- Run `make mdf-ha-drill`; transcribe row to `docs/ha-drill-history.md`.
- Bump STF submodule pin (`mdf-submodule-update`); re-run perf baselines.
- Audit `cloudflare/access-policy.json` — anyone left, anyone new?
- Refresh R2 lifecycle policy: keep recordings 90d, snapshots 365d.

## Useful URLs

- Operator UI:    https://mdf.mayaos.dev
- OTA browser:    https://ota.mayaos.dev
- Grafana:        https://mayaos.grafana.net (mdf-fleet, mdf-plugins)
- RunPod:         https://runpod.io/console
- Cloudflare:     https://dash.cloudflare.com/{ACCOUNT}

## See also

- `mdf/README.md`              — provisioning details
- `command-center/README.md`   — orchestrator architecture
- `docs/ha-runbook.md`         — HA topology + failover
- `docs/perf-baseline-rev5.1.md` — Phase 4.5 numbers
- `docs/perf-density-rev5.1.md`  — Phase 7 numbers
- `command-center/docs/plugin-api.md` — REST + WS contract
- `ota/README.md`              — OTA channel layout
