# MDF observability

Grafana Cloud dashboards + alerts shipped via versioned JSON. Metrics
flow via Grafana Alloy on each pod (already configured by the n8n
parent stack); MDF adds:

- 4 dashboards: fleet, plugin (mitm/rec/ota/hvf), R2 / OTA pipeline, host
- 12 alerts (see `alerts/`)
- 3 Alloy scrape jobs

```
observability/
├── README.md                       you're reading it
├── dashboards/
│   ├── mdf-fleet.json              instance count, boot histograms, queue depth
│   ├── mdf-plugins.json            mitm QPS, rec sessions, ota attempts, hvf handoffs
│   ├── mdf-ota-pipeline.json       channel publish rate, R2 lag, build SHA freshness
│   └── mdf-host.json               cgroup CPU per slice, KSM dedupe, GPU mem
├── alerts/
│   ├── instance-count-degraded.yml < 80% of target for >5m
│   ├── boot-p99-spike.yml          boot p99 > 90s for >5m at tier-100+
│   ├── checkout-latency-spike.yml  warmpool checkout p99 > 500ms for >5m
│   ├── mitm-flow-stall.yml         no flows for any active session for >2m
│   ├── recording-r2-lag.yml        R2 upload lag > 60s for >5m
│   ├── ota-channel-stale.yml       no new build in stable for >7d
│   ├── ksm-dedupe-low.yml          KSM sharing < 30% RSS at tier-100+
│   ├── tunnel-down.yml             cloudflared health check fail for >2m
│   ├── rethinkdb-replica-lag.yml   secondary lag > 30s
│   ├── disk-pressure.yml           /var/lib/mdf > 80%
│   ├── nvenc-saturation.yml        NVENC sessions > 80% of card limit for >5m
│   └── access-denied-spike.yml     Cloudflare Access deny rate > 10/min for >5m
├── alloy/
│   └── mdf.river                   Alloy config fragment for MDF metrics + logs
└── scripts/
    ├── push-dashboards.sh          push JSON to Grafana Cloud via API
    ├── push-alerts.sh              push alert rules
    └── lint-dashboards.sh          jsonnet lint + UID uniqueness
```

## Bring-up

```bash
make mdf-observability-push    # one-shot: lint + push dashboards + alerts
```

This calls into:
- `bash scripts/lint-dashboards.sh`
- `bash scripts/push-dashboards.sh`
- `bash scripts/push-alerts.sh`

…all of which read `${GRAFANA_CLOUD_API_TOKEN}` and the URLs from `.env`.

## Metrics surface

`mdf-plugin-*` plugins expose `/metrics` on port 7190 (Prometheus
text format). Alloy scrapes them every 15s and pushes via the
existing Grafana Cloud Mimir endpoint.

Notable series:

- `mdf_instances_total{pod, status}`         (count of qemu instances)
- `mdf_boot_duration_seconds{kind, pod}`     (cold|warm cold-boot histogram)
- `mdf_warmpool_size{pod, status}`           (ready|booting|assigned)
- `mdf_warmpool_checkout_seconds{pod}`       (allocation latency histogram)
- `mdf_mitm_flows_total{pod, serial, phase}` (counter)
- `mdf_rec_sessions_active{pod}`             (gauge)
- `mdf_ota_attempts_total{channel, state}`   (counter)
- `mdf_ota_channel_publish_age_seconds{channel}` (gauge)
- `mdf_r2_upload_lag_seconds{kind}`          (gauge)
- `mdf_hvf_handoffs_total{pod}`              (counter)

## Logs surface

JSON lines from supervisord-managed processes go via Alloy to Loki:

- `{container_name="mdf", plugin="mitm"}`
- `{container_name="mdf", plugin="recording"}`
- `{container_name="mdf", source="qemu"}`         (per-instance qemu)
- `{container_name="mdf", source="stf"}`
- `{container_name="rethink-1", source="rethinkdb"}`

LogQL panels in `mdf-fleet.json` already query these labels.

## References

- plan §9
- Grafana Alloy: <https://grafana.com/docs/alloy/latest/>
- Grafana Cloud Mimir + Loki API
