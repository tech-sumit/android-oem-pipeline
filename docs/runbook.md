# Alert runbook

Anchor links match the `runbook:` field in `observability/alerts/*.yml`.

## #instance-count-degraded

Symptom: ready instances < 80% of warmpool target for >5m.

Triage:
1. `make mdf-pod-status` — which qemu instances are running?
2. `journalctl -u qemu-*.service | tail -200` — crash trace?
3. `df -h /var/lib/mdf` — disk pressure?
4. `free -h` — memory exhausted?

Fix:
- Restart crashed instances: `make mdf-restore` per affected serial.
- If pool is too aggressive for available RAM, drop the warmpool
  target via `POST /mdf/warmpool/pool/size`.

## #boot-p99-spike

Triage:
1. Check `mdf-fleet` dashboard — KSM dedupe % and hugepage usage.
2. `iostat -xm 1 5` on the pod — is disk saturating?

Fix:
- Reduce warmpool target temporarily.
- Re-run `bash command-center/perf/parallel-boot.sh` with smaller `BATCH`.
- If KSM is paused (run=0), `echo 1 > /sys/kernel/mm/ksm/run`.

## #warm-restore-p99-spike

Triage:
1. Check QMP socket health: `ss -ltn | grep 4444`.
2. `dmesg | grep -i KVM` — KVM exhaustion?

Fix:
- Bounce the QMP socket per-instance: `make mdf-restore`.
- If many at once, bounce the whole `stf-provider-emulator` process.

## #checkout-latency-spike

Triage:
1. `curl /mdf/warmpool/pool` — pool empty?
2. Cold boot fallback should kick in within 30s.

Fix:
- Bump pool size 2x temporarily.
- Investigate the underlying boot regression.

## #mitm-flow-stall

Triage:
1. `adb -s <serial> shell iptables -t nat -L OUTPUT` — rules present?
2. `adb -s <serial> shell ss -ltn` — mitm port reachable from device?
3. `docker logs mdf | grep mitm` — addon errors?

Fix:
- Toggle intercept off/on (re-pushes iptables).
- If iptables NAT lost, factory-reset the device.

## #recording-r2-lag

Triage:
1. `aws s3 ls s3://android/mdf/ --endpoint $R2_ENDPOINT` — R2 reachable?
2. Check Cloudflare R2 status.

Fix:
- Wait it out; recordings stay on local disk via LRU.
- If disk fills, manually `rm -rf` oldest recordings (already in R2
  if upload succeeded).

## #ota-channel-stale

Triage:
1. Check `.github/workflows/ota.yml` runs.
2. `python3 ota/tools/append.py ...` to manually publish.

Fix:
- Manual append + `git push origin gh-pages-ota`.

## #ksm-dedupe-low

Triage:
1. `cat /sys/kernel/mm/ksm/run`.
2. `cat /sys/kernel/mm/ksm/pages_to_scan`.

Fix:
- `echo 1 > /sys/kernel/mm/ksm/run`.
- `echo 100 > /sys/kernel/mm/ksm/sleep_millisecs` (more aggressive).

## #cloudflare-tunnel-down

Triage:
1. `docker logs mdf-tunnel`.
2. https://www.cloudflarestatus.com/ — edge incident?

Fix:
- `docker compose restart mdf-tunnel`.
- If token revoked, re-pull from terraform output: `terraform output -raw cloudflare_tunnel_token`.

## #rethinkdb-replica-lag

Triage:
1. `docker compose exec rethink rethinkdb-cli` → `r.db('rethinkdb').table('server_status').run()`.

Fix:
- Restart the lagging replica.
- If majority lost, manually elect a new primary (see ha-runbook).

## #disk-pressure

Triage:
1. `du -sh /var/lib/mdf/* | sort -h | tail`.
2. Recordings the most likely culprit.

Fix:
- Trigger LRU eviction: `find /var/lib/mdf/recordings -mtime +7 -delete`.
- Verify R2 has the canonical copy first.

## #nvenc-saturation

Triage:
1. `nvidia-smi -q -d ACCOUNTING | grep -i nvenc`.

Fix:
- Reduce the number of focused-stream sessions.
- Software h264 (CPU-heavier) auto-picks up.

## #access-denied-spike

Triage:
1. Cloudflare dashboard → Access → Logs.

Fix:
- If credential rotation: re-issue tokens.
- If enumeration: tighten Access policy or rate-limit.
