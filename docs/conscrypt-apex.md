# Conscrypt APEX &mdash; v2 CA injection plan

> **Status:** v1 (system cacerts only) is what's wired up in this repo today.
> v2 (rebuild Conscrypt APEX) is documented here for when v1 turns out to be
> insufficient for your apps.

## Background

Up to Android 13, the trust store the Java security stack consulted at
runtime was `/system/etc/security/cacerts/`. Drop a hashed cert file there
and `KeyStore.getInstance("AndroidCAStore")` saw it. This is what the v1
strategy in this pipeline does, via `customos_cf_x86_64_phone.mk`'s
`PRODUCT_COPY_FILES`.

In Android 14+, the **Conscrypt APEX module** ships with its own bundled
trust store at `/apex/com.android.conscrypt/cacerts/`, and the runtime
resolution prefers it. The system path is still consulted, but only as a
fallback for legacy callers and for compatibility with certain
`sslcontext`-aware code paths. Apps that explicitly use the APEX-resolved
store (newer Play Services components, some MDM agents) will not see a CA
that lives only in `/system/etc/security/cacerts/`.

Apple writes about this in detail
[here](https://source.android.com/docs/core/architecture/modular-system/conscrypt);
GrapheneOS has a
[good writeup](https://grapheneos.org/articles/network-security)
on what changed in 14+ and why.

## Symptoms that say "you need v2"

- Banking app rejects your CA even though a `curl --capath /system/etc/security/cacerts/` against your endpoint succeeds from the
device shell.
- DRM-protected video apps (Widevine L1/L3 negotiation) refuse your proxy.
- An MDM client refuses to enroll citing "untrusted CA".

If apps just work after a v1 build, you don't need v2.

## What v2 entails

To get our CA into the APEX trust store, we have to **rebuild the Conscrypt
APEX module** with our anchors merged in. Steps:

1. **Locate the APEX source** in the AOSP tree:
  ```text
   external/conscrypt/apex/
  ```
2. **Find the bundled trust anchors**. They live in:
  ```text
   external/conscrypt/apex/com.android.conscrypt/etc/security/cacerts/
  ```
   Each is a `<hash>.0` file just like the system store.
3. **Splice our CAs into that directory** during the `after-sync` hook,
  exactly like we do for `/system/etc/security/cacerts/`. The dual-stage
   `after-sync.sh` would look like:
4. **Re-sign the APEX**. AOSP signs APEXes with one of the test keys by
  default. For Cuttlefish + dev builds this Just Works because verified
   boot is permissive. For real-device or production-grade builds you'd
   need the matching APEX signing key.
5. **Build with the modified APEX**. `m` picks up the new contents
  automatically because `external/conscrypt/Android.bp` globs the cacerts
   dir.
6. **Verify on device**:
  ```bash
   adb shell ls /apex/com.android.conscrypt/cacerts/
   adb shell sha256sum /apex/com.android.conscrypt/cacerts/<hash>.0
  ```

## Why v2 is gated behind v1 first

- The APEX path is more invasive and breaks reproducibility against
upstream more aggressively (`external/conscrypt` is now a forked
subtree).
- For ~80% of real-world apps, v1 is sufficient. Validating v1 first
tells us whether we even need v2.
- If we ship v2 prematurely and AOSP changes the APEX layout (it has,
twice, between Android 14 and 16), we have to chase the change. Less
surface area = less to maintain.

## v2 readiness checklist

- One full v1 build is green and boots on Cuttlefish.
- At least one app demonstrably fails with v1 (test plan: GBoard
or any modern Play-Services-backed app vs. a fake mitmproxy). If
no app fails, stop here &mdash; you don't need v2.
- Decide whether to fork `external/conscrypt` into our own git or
patch in-place via `repo` `<copyfile/>` directives.
- Wire the APEX-cacerts splice into `pipeline/hooks/after-sync.sh`
behind a `CA_STRATEGY=v2` env var so v1 stays the default.
- Add a verification step to `scripts/verify-image.sh`:
  ```
  ```bash
  adb shell ls /apex/com.android.conscrypt/cacerts/
  ```
  ```
- Document the upstream-fork delta in `docs/upstream-deltas.md`.

## References

- AOSP source: [https://android.googlesource.com/platform/external/conscrypt](https://android.googlesource.com/platform/external/conscrypt)
- Conscrypt APEX overview: [https://source.android.com/docs/core/architecture/modular-system/conscrypt](https://source.android.com/docs/core/architecture/modular-system/conscrypt)
- GrapheneOS network security: [https://grapheneos.org/articles/network-security](https://grapheneos.org/articles/network-security)
- AOSP "Adding a CA Certificate" (system cacerts path, what we do today):
[https://source.android.com/docs/security/features/encryption/digital-certificates](https://source.android.com/docs/security/features/encryption/digital-certificates)

