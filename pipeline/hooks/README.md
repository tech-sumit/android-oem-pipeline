# Pipeline hooks

`init.sh` invokes hooks at well-defined phases. Each hook is a standalone
shell script that can be overridden by mounting your own version at the same
path inside the container.

| Phase | Hook script | Default behavior |
|---|---|---|
| 1 | `before-sync.sh` | No-op. Override to mutate the manifest, set up extra git mirrors, etc. |
| 2 | &mdash; | `repo init` + `repo sync` (built-in to `init.sh`) |
| 3 | `after-sync.sh` | **Copies our device tree into `device/mayaos/` and our CA certs into `device/mayaos/galaxy-s26-ultra/security/cacerts/`.** This is the main customization seam. |
| 4 | `before-build.sh` | No-op. Override to apply patches, run `prebuilts/python` setup, etc. |
| 5 | &mdash; | `lunch ${LUNCH_TARGET} && m -j${JOBS}` (built-in) |
| 6 | `after-build.sh` | Bundles `cvd-host_package.tar.gz` and `*.img` into `${OUT_DIR}/`. |
| - | `on-failure.sh` | Runs only on non-zero exit. Default: dumps last 200 lines of the build log. |

A hook that doesn't exist is a no-op. A hook that exists and exits non-zero
aborts the pipeline.

All hooks run as the `build` user with `set -Eeuo pipefail` already in
effect (via `lib.sh`); they can rely on `log_info`, `log_warn`, `log_phase`,
and `cert_hash_filename` helpers being available.
