# HA runbook (Phase 10)

## Topology

```
                       ┌────────────────────────────┐
                       │  Cloudflare DNS (proxied)  │
                       │   *.mdf.mayaos.dev         │
                       └──────────────┬─────────────┘
                                      │ active/active
                  ┌───────────────────┴───────────────────┐
                  ▼                                       ▼
        ┌────────────────────┐                  ┌────────────────────┐
        │  pod-0 (eu-de)     │                  │  pod-1 (eu-de)     │
        │  cloudflared       │                  │  cloudflared       │
        │  STF + provider    │                  │  STF + provider    │
        │  rethink-1 (P)     ◀───── 29015 ─────▶│  rethink-2 (S)     │
        │  N/2 emulators     │                  │  N/2 emulators     │
        └────────────────────┘                  └────────────────────┘
                  │                                       │
                  ▼                                       ▼
          R2 snapshots (1/hr)                     R2 snapshots (1/hr)
```

- Both pods serve the same `*.mdf.mayaos.dev` wildcard. Cloudflare's
  HTTP load-balancer (single tunnel pool) decides which pod handles
  each request.
- RethinkDB cluster mode replicates all `mdf` tables with replicas=2
  + write_acks=majority + durability=hard. A single-pod failure does
  NOT lose any committed write.
- Recordings + mitm flows are uploaded to R2 in real time, so a pod
  loss cannot lose them either.
- The `rethink-backup` sidecar dumps the local RethinkDB to R2 every
  hour; in the worst case (both pods nuked simultaneously) we lose
  at most 1h of state.

## Bring-up

```bash
POD0_HOST=mdf-pod-eu-de-0 \
POD1_HOST=mdf-pod-eu-de-1 \
bash mdf/scripts/mdf-ha-setup.sh
```

## Monthly failover drill

Cron-friendly:

```bash
0 4 1 * *  POD0_HOST=mdf-pod-eu-de-0 POD1_HOST=mdf-pod-eu-de-1 \
           bash /opt/mdf/scripts/mdf-failover-drill.sh
```

The drill:

1. Writes a known marker into RethinkDB via pod-0.
2. Kills pod-0's `mdf` container.
3. Reads the marker via pod-1; records latency.
4. Restarts pod-0.
5. Appends a row to `docs/ha-drill-history.md`.

If the drill fails:

1. Page on-call (`mdf-operator` group).
2. Run `make mdf-status` -- check that pod-1 even thinks it's healthy.
3. SSH to pod-1, `docker logs rethink` -- look for "lost contact with
   primary" or "lost majority" messages.
4. If RethinkDB lost majority, manually elect pod-1 primary:
   ```
   r.db('rethinkdb').table('table_config').filter({db: 'mdf'}).update({primary_replica_tag: 'pod-1'}).run()
   ```

## Cost

Two pods at $0.79/hr each (A6000 SECURE) = $1.58/hr ≈ $1,140/month
when both running 24x7. Per-instance cost halves at the cost of
doubling the bill -- for production this is the correct tradeoff
because **no data loss ever** (per the user's locked decision).

## What we accept losing

- In-flight WebRTC frames during the failover window (1-3s)
- The single in-flight QMP control message at the moment of failure

## What we never lose

- Any RethinkDB row that's been ack'd (= every device, session,
  recording manifest, mitm flow row, OTA attempt)
- Any R2-uploaded recording or mitm flow payload
- Any committed channel index update (Cloudflare Pages)

## See also

- `command-center/docker-compose.ha.yml`
- `mdf/scripts/mdf-ha-setup.sh`
- `mdf/scripts/mdf-failover-drill.sh`
- plan §10
