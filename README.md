# android-oem-pipeline

> **CustomOS** &mdash; an OEM flavor of Android 16 (AOSP `android-16.0.0_r4`) targeting Cuttlefish (`vsoc_x86_64`), with custom root CA certificates baked into the system image and an end-to-end build pipeline that runs on rented Vast.ai compute.

This repository is the **build pipeline** &mdash; not the AOSP source itself. AOSP source (~250 GB) is fetched fresh on each build instance via `repo sync`. Our delta is small: a device tree under `device/customos/customphone/`, a few CA certs, and the orchestration scripts that drive the build.

---

## Why this exists

Standard Android emulators and stock OS images don't accept arbitrary corporate / lab root CAs as system-trusted. Apps that pin to the system trust store (most banking, MDM, and DRM-aware apps) reject MITM proxies even when the CA is added to the user trust store.

The fix is to ship a **custom system image** where the CA lives in `/system/etc/security/cacerts/` (and, for Android 14+, in the Conscrypt APEX runtime trust store) so it's indistinguishable from a CA that shipped with the device. This pipeline produces that image, reproducibly, in the cloud.

## What's in the box

| Layer | Purpose | Reuses |
|---|---|---|
| `docker/Dockerfile` | Reproducible AOSP 16 build environment (Ubuntu 22.04 + JDK 21 + ccache + `repo`) | Patterns from [`alexanderwolz/aosp-docker`](https://github.com/alexanderwolz/aosp-docker) and [`cdlee/aosp-builder`](https://hub.docker.com/r/cdlee/aosp-builder) |
| `pipeline/init.sh` + `pipeline/hooks/` | Env-var-driven build orchestration with hookable phases (`before-sync`, `after-sync`, `before-build`, `after-build`) | Hook contract modeled on [`lineageos4microg/docker-lineage-cicd`](https://github.com/lineageos4microg/docker-lineage-cicd) |
| `device-tree/customos/customphone/` | Custom OEM device tree (lunch combo `customos_cf_x86_64_phone-userdebug`) | Inherits `device/google/cuttlefish/vsoc_x86_64/aosp_cf.mk` |
| `manifests/customos.xml` | `repo` local manifest fragment so AOSP source picks up our device tree | Standard `repo` mechanism |
| `ca/` | Root CA staging area (public PEMs only; private keys are gitignored) | &mdash; |
| `vast/` | Vast.ai instance lifecycle (search &rarr; provision &rarr; sync &rarr; build &rarr; fetch &rarr; destroy) | [`vastai`](https://pypi.org/project/vastai/) CLI |
| `scripts/` | Helper utilities: generate demo CA, add a CA, verify a built image, version bump | &mdash; |
| `docs/` | Architecture, runbook, Conscrypt APEX deep-dive | &mdash; |

See [`docs/architecture.md`](docs/architecture.md) for the full architecture and rationale.

## Quickstart

### 0. One-time prerequisites (local control plane)

```bash
# Vast.ai CLI (used to drive the cloud build)
pipx install vastai

# gh CLI (only if you'll cut releases / manage PRs)
gh auth login

# Linux/WSL2 shell. Windows PowerShell is NOT supported as the control plane;
# use WSL2 (Ubuntu 22.04 recommended).
```

Set up secrets:

```bash
# Vast.ai API key
echo "<YOUR_VAST_KEY>" > vast_api_key
chmod 600 vast_api_key

# (Optional) Replace the demo CA with your real root CA(s)
./scripts/add-ca.sh /path/to/your-root.pem
```

### 1. Provision a Vast.ai build host

```bash
./vast/search.sh                  # show top 5 candidate offers (~32 vCPU / 64 GB / 1 TB)
./vast/provision.sh <offer_id>    # rent the chosen instance, save id to vast/.instance_id
./vast/ssh.sh                     # interactive ssh (sanity check)
```

### 2. Push the pipeline + kick the build

```bash
./vast/sync-source.sh             # rsync this repo + ca/ + device-tree/ to the instance
./vast/kick-build.sh              # docker run on remote, streams logs back to your terminal
                                  # ~250 GB repo sync (~2h) + ~3-4h build = ~5-7h end-to-end
```

### 3. Pull artifacts and destroy the instance

```bash
./vast/fetch-artifacts.sh         # scp out/target/product/vsoc_x86_64/*.img + cvd-host_package.tar.gz
./vast/destroy.sh                 # stop billing
```

### 4. Boot the image locally with Cuttlefish

```bash
# Requires Linux with KVM. Cuttlefish does NOT run on Windows or macOS hosts.
sudo apt install -y google-cuttlefish-base google-cuttlefish-use
mkdir cf && cd cf
tar xvf ../cvd-host_package.tar.gz
unzip ../customos_cf_x86_64_phone-img-*.zip
HOME=$PWD ./bin/launch_cvd

# In another terminal, verify our CA is present:
./scripts/verify-image.sh
```

## What's already done vs what's pending

- [x] Device tree skeleton and product makefile
- [x] Demo CA generated and placed at `device-tree/customos/customphone/security/cacerts/0899db77.0`
- [x] Dockerfile + entrypoint + hook contract
- [x] Vast.ai lifecycle scripts (skeletons; tested end-to-end on first build)
- [x] Documentation and runbook
- [ ] First successful AOSP 16 build on Vast.ai (next milestone)
- [ ] Conscrypt APEX rebuild path for Android 14+ runtime trust (see [`docs/conscrypt-apex.md`](docs/conscrypt-apex.md))
- [ ] CI smoke test (boot the built image, `adb` assertions on `ro.product.brand` + `openssl s_client` against a CA-signed endpoint)

## Cost guardrails

The default `vast/search.sh` filter targets ~$0.30&ndash;0.60 / hr instances. A full clean build (sync + lunch + `m`) is roughly:

| Phase | Wall time | $0.40/hr cost |
|---|---|---|
| `repo sync` (cold) | ~2 h | ~$0.80 |
| First `m` (cold ccache) | ~3-4 h | ~$1.20-1.60 |
| Repackage / fetch | ~30 min | ~$0.20 |
| **Total cold build** | **~6 h** | **~$2.20-2.60** |
| Subsequent incremental builds (warm ccache) | ~30-60 min | ~$0.20-0.40 |

`ccache` and the AOSP source live on the instance's NVMe; if you destroy the instance, the next build is cold again. To preserve them across runs, snapshot to S3 / Backblaze (see [`docs/vast-runbook.md`](docs/vast-runbook.md#preserving-ccache-and-source-across-runs)).

## Security model

- **Private keys** (CA private keys, signing keys, Vast API key) are **never committed**. `.gitignore` enforces this; `LICENSE` calls it out.
- **Demo CA** (`ca/customos-root-ca.pem`) is committed for first-run convenience &mdash; it is **public** and self-signed, has no power. The matching `customos-root-ca.key` is **not** committed and was discarded after the demo cert was generated. To use a real CA, run `scripts/add-ca.sh /path/to/real.pem` &mdash; the public PEM gets staged into the device tree, the private key never enters the repo.
- **Build signing** uses the AOSP-default test keys for now. Production builds should use a dedicated signing key set; see [`docs/architecture.md#signing`](docs/architecture.md#signing).
- **CA injection** strategy is v1 (system cacerts) by default; v2 (rebuild Conscrypt APEX) is documented in [`docs/conscrypt-apex.md`](docs/conscrypt-apex.md) for Android 14+ hardening.

## Layout

```text
.
├── docker/          AOSP build containe
├── device-tree/     Our OEM customizations
├── manifests/       repo local_manifests fragment
├── ca/              Public PEMs only (private keys gitignored)
├── pipeline/        Container entrypoint + hooks
├── vast/            Vast.ai lifecycle scripts
├── scripts/         Helpers (gen-ca, add-ca, verify-image, bump-version)
├── .github/         Lint workflow + release workflow (tag-driven build)
└── docs/            Architecture, runbook, Conscrypt APEX
```

## Acknowledgments

This pipeline is a fresh implementation but openly borrows mechanics from the open-source community. Specifically:

- [`lineageos4microg/docker-lineage-cicd`](https://github.com/lineageos4microg/docker-lineage-cicd) &mdash; the env-var + volume + hook contract is modeled on theirs, simplified for pure AOSP and a single device target.
- [`alexanderwolz/aosp-docker`](https://github.com/alexanderwolz/aosp-docker) &mdash; clean reference for AOSP 14+ build dependency lists.
- [`google/android-cuttlefish`](https://github.com/google/android-cuttlefish) &mdash; the runtime we use to boot the built image and verify it.
- [`LineageOS-UL/android_device_google_cuttlefish`](https://github.com/LineageOS-UL/android_device_google_cuttlefish) &mdash; reference for layering custom branding on top of `device/google/cuttlefish`.

## License

Proprietary &mdash; see [`LICENSE`](LICENSE). The AOSP source pulled at build time remains Apache-2.0 and is **not** redistributed by this repo.
