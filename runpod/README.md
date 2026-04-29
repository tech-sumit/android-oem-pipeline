# RunPod backend for the MayaOS AOSP build

This directory mirrors `vast/` for the second compute backend. Same `pipeline/`
code runs on both; only the lifecycle (provision / sync / kick / fetch / destroy)
scripts differ.

Use RunPod when you need:

- A pod that won't be reclaimed mid-build (SECURE cloud comes with an SLA).
- A persistent `/workspace` volume that survives stop/start (GPU pods only;
  CPU pods need a pre-created network volume).
- Public IPv4 + full SSH (so `rsync` works for source sync and artifact
  fetch).

> **Why we default to GPU pods even though AOSP doesn't need a GPU.**
> Verified empirically against the live RunPod REST API on 2026-04-29:
> CPU pods do NOT receive a public IP address even on SECURE cloud
> (despite what the OpenAPI spec implies). The fallback "basic SSH" via
> `ssh.runpod.io` is a proxy that does not support SCP/SFTP, which breaks
> `rsync`. Only GPU pods get `publicIp` + `portMappings.22`. The cheapest
> viable GPU pod is `NVIDIA RTX A6000` x1 at ~$0.79/hr (16 vCPU, ~62 GB
> RAM) which is what we default to.

## One-time setup

```sh
# Drop your RunPod API key (starts with rpa_) somewhere we can find it.
echo 'rpa_your_key_here' > runpod_api_key
chmod 600 runpod_api_key

# OR
export RUNPOD_API_KEY=rpa_your_key_here
```

You'll also want an SSH keypair; `provision.sh` will generate one at
`~/.ssh/id_ed25519_runpod` if it doesn't exist.

## Lifecycle

```sh
# 1. Look at what's available (optional)
./runpod/search.sh cpu          # cheap CPU pods (default)
./runpod/search.sh gpu          # GPU pods (only if you want one for some reason)

# 2. Rent a pod
./runpod/provision.sh           # SECURE CPU pod, cpu5c x32 vCPU, 1 TB volume
# or with overrides:
RUNPOD_VCPU=64 RUNPOD_VOLUME_GB=2048 ./runpod/provision.sh

# 3. Kick the build (rsyncs the repo first, runs pipeline/init.sh under tmux)
./runpod/start-tmux-build.sh

# 4. Watch
./runpod/status.sh              # quick snapshot
./runpod/tmux-watch.sh          # attach to the live tmux
./runpod/ssh.sh 'tail -f /workspace/aosp-logs/mayaos-build.log'

# 5. Pull artifacts when the build finishes
./runpod/fetch-artifacts.sh

# 6. Tear down
./runpod/destroy.sh --stop      # halt compute, keep /workspace volume
./runpod/destroy.sh --start     # bring it back when you want to iterate
./runpod/destroy.sh --destroy   # delete everything (default)
```

## Tunables (env vars)

| var                        | default                              | what it does                                                  |
| -------------------------- | ------------------------------------ | ------------------------------------------------------------- |
| `RUNPOD_API_KEY`           | `runpod_api_key` file                | auth                                                          |
| `RUNPOD_SSH_KEY`           | `~/.ssh/id_ed25519_runpod`           | private key path; `.pub` injected via `PUBLIC_KEY` env        |
| `RUNPOD_CLOUD_TYPE`        | `SECURE`                             | `SECURE` (SLA) vs `COMMUNITY` (cheap, flaky)                  |
| `RUNPOD_COMPUTE_TYPE`      | `GPU`                                | `GPU` (rsync works) or `CPU` (proxy SSH only, breaks rsync)   |
| `RUNPOD_GPU_TYPE`          | `NVIDIA RTX A6000`                   | one of the gpuTypeIds in the OpenAPI enum                     |
| `RUNPOD_GPU_COUNT`         | `1`                                  | how many GPUs                                                 |
| `RUNPOD_CPU_FLAVOR`        | `cpu5c`                              | only for `RUNPOD_COMPUTE_TYPE=CPU`                            |
| `RUNPOD_VCPU`              | `32`                                 | only for CPU pods                                             |
| `RUNPOD_CONTAINER_DISK_GB` | `500`                                | ephemeral container disk (covers one full build)              |
| `RUNPOD_VOLUME_GB`         | `0`                                  | Pod-scoped volume at `/workspace` (GPU pods only)             |
| `RUNPOD_NETWORK_VOLUME_ID` | (none)                               | attach a pre-created network volume instead of `volumeInGb`   |
| `RUNPOD_IMAGE`             | `runpod/base:0.6.2-cuda12.4.1`       | base image (pre-configured sshd + `PUBLIC_KEY`)               |
| `RUNPOD_DATA_CENTER_IDS`   | (any)                                | CSV of data center ids (e.g. `EU-RO-1,US-IL-1`)               |
| `PROFILES`                 | `galaxy-s26-ultra-{intel-gpu,apple-silicon}` | mayaos.yaml profile ids to build                      |
| `SKIP_SYNC`                | `0`                                  | skip `repo init/sync` if you already have source              |

## A note on nsjail

RunPod pods (both CPU and GPU) don't enable user namespaces inside the
container, so `nsjail`'s `clone(CLONE_NEWUSER)` returns `EPERM` and Soong
falls back to "Build sandboxing disabled". This is the *same* behavior we
already validated on Vast.ai - the build still produces correct artifacts;
it just gives up sandbox isolation.

## Persisting `/workspace` across stop/start (GPU pods)

When you provision with `RUNPOD_VOLUME_GB=1024`, RunPod attaches a
Pod-scoped volume at `/workspace`. After `make runpod-stop` (which halts
billing for compute) the volume is preserved; `make runpod-start` brings
the same pod back up with the AOSP source, ccache, and `out/` intact. This
is the killer feature vs Vast.ai marketplace offers, where stop usually
means losing the disk.

To share the volume across multiple pods (e.g. switch from a 1xA6000 to a
4xA40 mid-project), pre-create a network volume in the RunPod console and
pass `RUNPOD_NETWORK_VOLUME_ID=<id>` instead of `RUNPOD_VOLUME_GB`.
