# Waydroid-style image layout (rev 5)

## What changed

In rev 4, MayaOS bundled the per-device .mk, the vendor binaries, the
features XML, and the CAs into a single `device-tree/mayaos/galaxy-s26-ultra/`
directory. That worked for one profile but conflated three concerns and
made it impossible to share state across profiles cleanly.

Rev 5 adopts the Waydroid 3+1-layer pattern. See
[`aosp-tree/README.md`](../aosp-tree/README.md) for the layout guide.

## Splice contract

The `pipeline/hooks/after-sync.sh` hook splices `aosp-tree/` into the
freshly synced AOSP source like so:

| Source (this repo) | Destination (inside AOSP source) |
|---|---|
| `aosp-tree/device/mayaos/<device>/` | `$AOSP_SRC/device/mayaos/<device>/` |
| `aosp-tree/hardware/mayaos/` | `$AOSP_SRC/hardware/mayaos/` |
| `aosp-tree/vendor/mayaos/` | `$AOSP_SRC/vendor/mayaos/` |
| `aosp-tree/packages/apps/<App>/` | `$AOSP_SRC/packages/apps/<App>/` |

The splice is destructive — every build wipes the destination and copies
fresh from `aosp-tree/`, so a `git status` inside AOSP is always clean
except for our overlay.

## Per-device .mk inheritance order

A per-device .mk (e.g. `aosp-tree/device/mayaos/galaxy-s26-ultra/mayaos_emu_s26ultra.mk`)
inherits in this order:

1. **Upstream base** (Cuttlefish or sdk_phone goldfish) — provides the
   board, kernel, partitions, GPU stack.
2. **Per-profile overrides** — `PRODUCT_NAME`, `PRODUCT_DEVICE`, ABI
   list, OEM build-tag suffix.
3. **Shared MayaOS spoof block** — `vendor/mayaos/product.mk` — the
   complete `ro.product.*` per-partition spoof, `BUILD_FINGERPRINT`,
   AAPT density, SF tuning, `mayaos.prop` bake, the CA wildcard,
   `PRODUCT_PACKAGES` for the MayaOS payload.

Order matters: AOSP's `inherit-product` is "first-wins" — the inherit at
the bottom of a .mk **doesn't** override values set above it. We set
profile-specific values at the top and inherit the shared block last so
the shared block fills in everything we didn't override.

## Adding a new profile

To add (say) `pixel-8-pro` as a fifth profile:

1. Create `aosp-tree/device/mayaos/pixel-8-pro/`.
2. Copy `mayaos_emu_s26ultra.mk` → `mayaos_pixel8pro.mk`, change the
   inherit base, `PRODUCT_NAME`, `PRODUCT_DEVICE`, ABI list, OEM tag.
3. Create the matching `AndroidProducts.mk` registering the lunch combo.
4. (Optional) Create `mayaos_pixel8pro_features.xml` under `sku/` and
   add a `prebuilt_etc` module to `aosp-tree/device/mayaos/pixel-8-pro/Android.bp`.
5. Add the profile entry to `mayaos.yaml` with `device_tree:
   aosp-tree/device/mayaos/pixel-8-pro` and `enabled: true`.
6. **Decide whether the spoof block should differ from S26 Ultra.** If
   yes, you'll need to either fork `vendor/mayaos/product.mk` or
   parameterize it on a profile macro. If no, you're done — every
   profile that inherits `vendor/mayaos/product.mk` gets the same spoof.

## Adding a new HAL

1. Create `aosp-tree/hardware/mayaos/<hal>/` (e.g.
   `aosp-tree/hardware/mayaos/audio/`).
2. Reference the upstream Waydroid HAL of the same name as a starting
   point (e.g. `waydroid/android_hardware_waydroid` `audio/`).
3. Add the `Android.bp` modules.
4. Wire it into `vendor/mayaos/product.mk`'s `PRODUCT_PACKAGES` so every
   profile gets the HAL by default.

## Adding a CA

```bash
./scripts/add-ca.sh /path/to/your-root.pem
```

That stages the PEM under both `ca/` and
`aosp-tree/vendor/mayaos/rootdir/system/etc/security/cacerts/<hash>.0`
(rev 5 vendor-partition path). The next build picks it up via the
wildcard in `aosp-tree/vendor/mayaos/product.mk`.

## Verification

```bash
# 1. In-source assertions (64 invariants between yaml + mk + bp).
python3 scripts/validate-mayaos.py

# 2. Bash + dockerfile syntax.
make validate

# 3. CI parity (yaml <-> shared mk <-> AndroidProducts.mk).
gh workflow run lint.yml
```

Once a build completes against rev 5, the gold-standard validation is
to sha256-compare `out/target/product/<board>/system.img` and
`vendor.img` against a Phase 0 (rev 4) build — they should match
modulo the build timestamp embedded in
`/system/build.prop:ro.build.date.utc` and `vendor/build.prop`'s
equivalent.
