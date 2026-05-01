# Fleet console (local)

A single-page operator UI for watching the AOSP build progress, the STF
device farm logs, and the R2 → fleet deploy watcher — all from one
browser tab on the operator's mac. Runs entirely locally; the pods
themselves are not modified.

## What it shows

Three live log panels + a STF launcher panel:

1. **AOSP build** — tails `/workspace/aosp-logs/mayaos-x86-build.log` on
   the builder pod. Parses `[NN% MM/TT]` lines into a top-of-page
   progress bar with ETA. Classifies cosmetic ninja warnings as
   `system` (greyed) and real `FAILED:` / `error:` lines as `error`
   (red), so a healthy long-running build stays visually quiet.
2. **STF / DeviceFarmer** — tails `/var/log/stf/stf.log` on the fleet
   pod. Surfaces `Provider configured` / `Tracking <serial>` /
   `Lost device` events.
3. **MayaOS x86 deploy watcher** — tails
   `/var/log/mayaos-watcher.log` on the fleet pod. Watches R2 for the
   freshly-built MayaOS x86_64 emu/ bundle and, when it appears,
   downloads it and replaces the stock_x86_NNN AVDs with MayaOS-branded
   ones using the same adb ports so STF re-detects the new serials
   transparently.
4. **Device launcher** — `GET /api/devices` is polled every 10s and
   rendered as one card per device (serial, model, ready/using badges,
   display dims). Clicking a card opens STF's per-device control page
   in a new browser window so each device gets first-party cookies and
   doesn't fight STF's CSRF / iframe-cookie partitioning.

The build, STF, and watcher logs are streamed by background daemon
threads in `server.py` (`tail_loop`); each thread runs an `ssh ... tail
-F` against the relevant pod and feeds every line into an in-memory
ring buffer. The browser polls `GET /log/<name>?since=<seq>` once a
second for new lines. SSH is paid once per stream, regardless of how
many viewers / browser tabs are open.

## Quickstart

```bash
./start.sh                # opens persistent SSH tunnels to the fleet pod,
                          # starts the python server on :8080, opens browser
./start.sh status         # show running pids
./start.sh stop           # tear down tunnels + server
```

Default targets bake in the current pod IPs. To point at different
pods (e.g. after a respawn), override via env:

```bash
FLEET_HOST=root@<new-fleet-ip> FLEET_PORT=<new-port> \
BUILDER_HOST=root@<new-builder-ip> BUILDER_PORT=<new-port> \
    ./start.sh
```

## Environment knobs (server.py)

| var | default | purpose |
|---|---|---|
| `FLEET_CONSOLE_PORT` | `8080` | Local HTTP port |
| `BUILDER_HOST` | `root@38.147.83.25` | SSH target for build log tail |
| `BUILDER_PORT` | `47023` | SSH port on builder |
| `BUILD_LOG` | `/workspace/aosp-logs/mayaos-x86-build.log` | Log path on builder |
| `FLEET_HOST` | `root@38.147.83.24` | SSH target for STF + watcher logs |
| `FLEET_PORT` | `37662` | SSH port on fleet |
| `STF_LOG` | `/var/log/stf/stf.log` | STF log path on fleet |
| `WATCHER_LOG` | `/var/log/mayaos-watcher.log` | Watcher log path on fleet |
| `BUFFER_LINES` | `1200` | Per-stream ring buffer size |
| `DEVICE_POLL_INTERVAL` | `10` | rethinkdb device-state poll cadence (s) |
| `FLEET_SSH_KEY` | `~/.ssh/id_ed25519_runpod` | Private key for both SSH targets |

## SSH port forward matrix

`start.sh` forwards a wide range of ports from the fleet pod so STF's
per-device screen streams reach the browser. The full list:

| port(s) | purpose |
|---|---|
| 7100 | STF main HTTP entry (UI + API + auth proxy) |
| 7102-7106 | STF backend services (app, processor, ws sidecars, image plugin) |
| 7110 | STF websocket gateway (browser opens this directly for live device events) |
| 7120 | STF auth-mock backend |
| 7400-7700 | STF provider port pool (2-3 ports per device: minicap stream + minirev) |

The 7400-7700 range needs to be **fully** tunneled because STF picks a
fresh port from this pool every time a device appears. With even one
port missing, that device shows up in the STF UI but the screen
silently fails to load. macOS's default `ulimit -n 256` is too low for
this many forwards; `start.sh` bumps it to 4096 for the SSH subshell.

## HTTP API

| method | path | response |
|---|---|---|
| GET | `/` | `index.html` |
| GET | `/health` | `{ok: true, streams: {build: <seq>, stf: <seq>, watcher: <seq>}}` |
| GET | `/api/devices` | `{total, ready, using, list: [{serial, model, ready, using, width, height}]}` |
| GET | `/log/<name>?since=<seq>` | `{lines: [[seq, line], ...], next: <seq>}` for `name in {build, stf, watcher}` |

`since=` lets the browser do efficient incremental polling — pass back
the previous response's `next` field as the next request's `since`.
Unknown stream names 404.

## Troubleshooting

**Build log stuck on a stale percentage** — the `tail -F` ssh process
sometimes outlives a log rotation, especially when the symlink
`mayaos-x86-build.log` is repointed to a new file. Fix:

```bash
pkill -f 'ssh.*tail.*aosp-logs/mayaos-x86-build.log'
```

The python server's `tail_loop` auto-reconnects within 2s and starts
streaming the new symlink target.

**`AccessDenied` flooding the watcher log** — the R2 token currently in
`/etc/mdf/r2.env` on the fleet pod doesn't have access to the bucket
the watcher polls. See [`docs/build-runbook.md`](../../docs/build-runbook.md)
§ "R2 bucket scoping". The watcher refuses to run unless
`ANDROID_CREDS_VERIFIED=1` is set in `/etc/mdf/r2.env` — flip that flag
**only after** verifying the credentials with `aws s3api head-bucket`.

**Devices appear in STF but screens are blank** — almost always the
SSH tunnel didn't get a port in the 7400-7700 range up. Check
`tunnel.log` in `$RUNDIR` (default `~/.cache/mayaos-fleet-console/`)
for `bind: Address already in use` errors.

**STF screen pumps die after ~30s** — STF defaults to
`--screen-grabber minicap-bin`, which fails on Android 16 (missing
symbol `android::ui::Size::INVALID`). The fleet-pod-side STF install
patches `lib/cli/local/index.js` to force `minicap-apk` and inject
`--screen-jpeg-quality 40 --screen-frame-rate 15` to avoid saturating
the TCG-emulator CPU. If you re-bootstrap STF, re-apply these patches
or the streams will silently die.

**Fleet pod IP changed / pod was respawned** — tunnel is stale. Run
`./start.sh stop` then start with the new env vars (see Quickstart
above). The browser tab will keep polling and will reconnect once the
new server is healthy.
