# Vast.ai runbook

Operational notes for the cloud-build path. Skip if you're building on
your own beefy Linux box (`docker compose -f docker/docker-compose.yml up`).

## Choosing an offer

`./vast/search.sh` filters by:

| Knob | Default | Why |
|---|---|---|
| `CPU_MIN` | 32 | AOSP 16 link step parallelizes well to ~32; diminishing returns past 64 because of memory bandwidth. |
| `RAM_MIN` | 64 G | The link step (`m`) peaks ~50 GB. 32 GB OOMs roughly 1 build in 5. |
| `DISK_MIN` | 1024 G | 250 source + 150 out + 50 ccache + 50 OS/Docker + headroom. |
| `NET_MIN` | 100 Mbps | `repo sync` over <100 Mbps doubles wall time. |
| `DPH_MAX` | $0.80/hr | Tighter cap is fine; loosen if no offers match. |

Override examples:

```bash
DPH_MAX=0.50 TOP_N=10 ./vast/search.sh   # cheaper, more candidates
CPU_MIN=64 ./vast/search.sh              # faster build, fewer candidates
```

The output is sorted by `dph_total` ascending. The cheapest offer is
usually the right call &mdash; AOSP build time is bandwidth- and
CPU-cores-bound, not GPU-bound, so paying for an A100 is wasteful.

## Cost ledger (sample)

Captured during initial pipeline development (April 2026):

| Phase | Wall time | Cost @ $0.40/hr |
|---|---|---|
| `repo sync` cold | 1h 53m | $0.75 |
| `m` cold ccache | 3h 12m | $1.28 |
| `repackage + scp` | 24m | $0.16 |
| **Total cold build** | **5h 29m** | **$2.19** |
| `repo sync` warm (next day) | 4m | $0.03 |
| `m` warm ccache (5 % delta) | 38m | $0.25 |
| **Total warm rebuild** | **42m** | **$0.28** |

## Preserving ccache and source across runs

By default `vast/destroy.sh` wipes the instance &mdash; next build is cold.
Three options to keep ccache + source warm:

1. **`./vast/destroy.sh --stop`** instead of `--destroy`. The instance is
   halted but its disk persists. You keep paying ~$0.05-0.10/hr for the
   disk, but resumes are instant. Best if you'll rebuild within ~24h.

2. **Snapshot to S3 / Backblaze B2** at end of build. Roughly:

   ```bash
   ./vast/ssh.sh 'cd /workspace && tar c aosp-ccache | zstd -T0 > ccache.tzst'
   ./vast/ssh.sh 'aws s3 cp /workspace/ccache.tzst s3://customos-ccache/$(date -u +%F).tzst'
   ./vast/destroy.sh
   ```

   Restore on a new instance with the inverse. ~50 GB ccache compresses to
   ~15 GB; B2 charges ~$0.005/GB/month, so storage is essentially free.

3. **Pin one instance**, never destroy it. Cleanest workflow, but you pay
   ~$10/day even when idle.

The pipeline is agnostic. `kick-build.sh` works with all three.

## Common failures and fixes

### `repo sync` aborts halfway

Cause: usually upstream Gerrit rate-limiting or network blip.

Fix:

```bash
./vast/ssh.sh 'cd /workspace/aosp-src && repo sync -j8 --force-sync'
SKIP_SYNC=0 ./vast/kick-build.sh   # re-run, sync will resume from where it stopped
```

### `m -j` OOMs near the link step

Cause: instance has too little RAM.

Fix:

- Confirm with `./vast/ssh.sh 'free -h'`. If `Mem: total < 64G`, the offer
  is undersized.
- Cap parallelism: `PARALLEL_JOBS=$(($(./vast/ssh.sh nproc) / 2)) ./vast/kick-build.sh`
- Or destroy and re-provision a 64 G+ offer.

### Build succeeds but `vast/fetch-artifacts.sh` returns nothing

Cause: `after-build.sh` couldn't find `out/target/product/vsoc_x86_64/`.
Probably a misnamed lunch combo or the build silently fell through.

Fix:

```bash
./vast/ssh.sh 'find /workspace/aosp-src/out -name "*.img" -size +10M | head'
```

If nothing matches, the build never produced images. Re-run with
`SKIP_SYNC=1` and inspect the streamed logs for errors.

### `docker build` fails with `Hash Sum mismatch`

Cause: an apt mirror failed mid-build.

Fix: re-run; apt mirror flips usually clear in <10min.

### Vast.ai instance gets evicted mid-build

Cause: you rented an interruptible offer.

Fix: `vast/search.sh` already filters to `rentable=true verified=true`
non-interruptible offers. If you still got hit, the host probably reclaimed
its hardware. Provision a different offer and use the snapshot strategy
above to resume from ccache.

## Security hygiene

- **Never push `vast_api_key` to git.** `.gitignore` blocks it; double-check
  with `git status` before every commit.
- **Vast.ai instances run untrusted code by definition.** Do not put real
  signing keys on a Vast instance unless you treat that instance as
  compromised the moment you destroy it. The Dockerfile leaves
  `/srv/keys` mountable but unfilled for exactly this reason &mdash; in
  production, signing should happen on a different, trusted host.
- **Rotate the SSH key** after a build campaign:
  `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_vastai -N ''` and re-attach.
