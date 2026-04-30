# MayaOS Device Farm — provisioning

Top-level provisioning, edge networking and operator commands. The
runtime stack lives under `command-center/`; this folder owns the
control-plane that brings up / tears down a fleet pod and wires the
edge so operators can reach it.

## Pieces

```
mdf/
├── README.md                you're reading it
├── scripts/
│   ├── mdf-provision.sh     end-to-end fleet pod bring-up
│   ├── mdf-status.sh        which pods are alive + how many devices
│   ├── mdf-destroy.sh       teardown + R2-snapshot last RethinkDB
│   ├── mdf-rotate-ca.sh     rotate the MDF root CA (expiring keys)
│   └── mdf-cloudflared.sh   bring up / tear down a Tunnel locally
├── terraform/
│   ├── main.tf              RunPod pod, R2 buckets, Cloudflare DNS
│   ├── variables.tf
│   └── outputs.tf
└── cloudflare/
    ├── tunnel-config.yml    sample cloudflared config
    └── access-policy.json   OIDC application + group bindings
```

## Lifecycle

```bash
# one-time: spin up infra (RunPod pod, R2 buckets, Cloudflare DNS)
make mdf-provision REGION=eu-de POD_TYPE=NVIDIA_RTX_A6000_SECURE

# day-to-day: see what's alive
make mdf-status

# emergency: tear it all down (snapshots RethinkDB to R2 first)
make mdf-destroy
```

## Cloudflare Tunnel

Each pod has a single `cloudflared` sidecar, named
`mdf-pod-${REGION}-${index}`. The Tunnel is configured to forward
`mdf-pod-${REGION}-${index}.mdf.mayaos.dev` to the in-pod nginx on
port 8080.

A wildcard `*.mdf.mayaos.dev` is configured in Cloudflare DNS to
target the Tunnel's CNAME, so adding a new pod is just:

1. `make mdf-provision REGION=...`  -> creates the pod + Tunnel
2. The Tunnel auto-registers itself; DNS is already wildcarded
3. Operator browses to `https://mdf-pod-eu-de-0.mdf.mayaos.dev`

## Cloudflare Access (OIDC)

Two policies enforced at the edge:

- `mdf-operator` (full access, sumit@mayaos.dev + invited users)
- `mdf-viewer`   (read-only views of the device grid)

Both back to the same Google Workspace IDP. Tokens are JWTs verified
by STF's auth middleware (configured `STF_AUTH_TYPE=oidc` +
`STF_OIDC_*`). Access also provides the user's email + groups in the
`Cf-Access-Authenticated-User-Email` and `Cf-Access-Jwt-Assertion`
headers, which we map to STF's `req.user`.

## Refs

- plan §8, §11
- <https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/>
- <https://developers.cloudflare.com/cloudflare-one/applications/configure-apps/self-hosted-public-app/>
