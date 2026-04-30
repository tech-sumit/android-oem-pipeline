#!/usr/bin/env bash
#
# Phase 3: after repo sync, before lunch.
#
# Splices the MayaOS device tree (every profile under /srv/devicetree/mayaos/*)
# into the freshly synced AOSP source at $SRC_DIR/device/mayaos/, then stages
# every CA in /srv/cacerts into EACH profile's security/cacerts/ subdir with
# the Android-style hashed filename.
#
# /srv/devicetree (host bind mount) is treated as authoritative -- we wipe
# device/mayaos in the AOSP tree and copy fresh on every build so a
# `git status` inside AOSP is always clean except for our overlay.
#
set -Eeuo pipefail
# shellcheck source=../lib.sh
source "/opt/pipeline/lib.sh"

DEVICE_DST="${SRC_DIR}/device/mayaos"

log_info "after-sync: splicing MayaOS device tree into AOSP source"

if [[ ! -d "$DEVICETREE_DIR/mayaos" ]]; then
    log_error "expected $DEVICETREE_DIR/mayaos to be bind-mounted; not found"
    exit 1
fi

# Refresh the device tree overlay.
rm -rf "$DEVICE_DST"
mkdir -p "$(dirname "$DEVICE_DST")"
cp -a "$DEVICETREE_DIR/mayaos" "$DEVICE_DST"
log_info "  copied $DEVICETREE_DIR/mayaos -> $DEVICE_DST"

# Stage CAs into every profile's security/cacerts dir. We discover profiles
# by globbing the device tree -- this avoids tying the after-sync hook to the
# yaml schema and means new profiles "just work" once their dir is created.
shopt -s nullglob
ca_count=0
for profile_dir in "$DEVICE_DST"/*/; do
    [[ -d "$profile_dir" ]] || continue
    profile_id="$(basename "$profile_dir")"
    cacert_dst="${profile_dir}security/cacerts"
    mkdir -p "$cacert_dst"

    # Hash + copy *.pem.
    for pem in "$CACERTS_DIR"/*.pem; do
        fname="$(cert_hash_filename "$pem")"
        cp "$pem" "${cacert_dst}/${fname}"
        ca_count=$((ca_count + 1))
        log_info "  ${profile_id}: staged $(basename "$pem") -> ${fname}"
    done

    # Accept already-hashed certs (gen-demo-ca.sh drops *.0 directly).
    for hashed in "$CACERTS_DIR"/*.0; do
        cp "$hashed" "${cacert_dst}/$(basename "$hashed")"
        ca_count=$((ca_count + 1))
        log_info "  ${profile_id}: staged $(basename "$hashed") (pre-hashed)"
    done
done
shopt -u nullglob

if [[ "$ca_count" -eq 0 ]]; then
    log_warn "no CAs found in ${CACERTS_DIR}; builds will use whatever is" \
             "already committed under each profile's security/cacerts/"
else
    log_info "  staged ${ca_count} CA cert(s) across all profiles"
fi

# Sanity: at least one AndroidProducts.mk must be visible.
if ! find "${SRC_DIR}/device/mayaos" -maxdepth 3 -name AndroidProducts.mk \
        | grep -q .; then
    log_error "no AndroidProducts.mk found under device/mayaos/; aborting"
    exit 1
fi

# ---- Container-environment workarounds for Android 16 (trunk_staging) ----
# Most managed Docker hosts (RunPod / Vast / GitHub Actions / GitLab Cloud)
# strip CAP_SYS_ADMIN from the container and the kernel then rejects every
# CLONE_NEW* flag. AOSP's `nsjail`-wrapped genrules can't run there, and a
# few specific genrules (notably `trusty_security_vm_*.elf`) fail outright.
# Two fixes below are idempotent and safe to apply unconditionally.

# 1. Replace the prebuilt nsjail with a Python "fakejail" that materializes
#    -B/-R bind mounts as symlinks inside the sandbox dir and execs the
#    inner command directly. We swap only when the kernel actually rejects
#    user namespaces; otherwise leave the real nsjail in place.
maybe_install_fakejail() {
    local nsjail="${SRC_DIR}/prebuilts/build-tools/linux-x86/bin/nsjail"
    [[ -x "$nsjail" ]] || return 0

    if unshare --user /bin/true 2>/dev/null; then
        log_info "  unshare --user works -> keeping real nsjail"
        return 0
    fi

    if [[ -f "${nsjail}.real" ]] && head -1 "$nsjail" 2>/dev/null \
            | grep -q '^#!/usr/bin/env python3'; then
        log_info "  fakejail already installed, skipping"
        return 0
    fi

    if [[ ! -f "${nsjail}.real" ]]; then
        cp "$nsjail" "${nsjail}.real"
        log_info "  backed up real nsjail -> nsjail.real"
    fi

    install -m 0755 \
        "/opt/pipeline/hooks/files/fakejail.py" \
        "$nsjail"
    log_info "  installed fakejail (CLONE_NEW* denied; namespaces bypassed)"
}

# 2. Trusty's build.py invokes `nice` unconditionally unless `--no-nice` is
#    passed -- but the Soong genrule wrapping it doesn't pass that flag and
#    AOSP's restricted PATH (`build-tools/path/linux-x86`) rejects host
#    `nice`. Force the python source to omit nice; soong rebuilds the
#    `build_trusty` PEX from this source, so the patch propagates.
patch_trusty_no_nice() {
    local bp="${SRC_DIR}/trusty/vendor/google/aosp/scripts/build.py"
    [[ -f "$bp" ]] || return 0

    if grep -q 'mayaos: AOSP restricted PATH disallows host nice' "$bp"; then
        log_info "  trusty build.py already patched (no-nice), skipping"
        return 0
    fi

    if ! grep -q 'nice = "" if args.no_nice else "nice"' "$bp"; then
        log_warn "  trusty build.py shape changed; not patching nice"
        return 0
    fi

    sed -i.mayaosbak \
        's|nice = "" if args.no_nice else "nice"|nice = ""  # mayaos: AOSP restricted PATH disallows host nice (RunPod/Vast)|' \
        "$bp"
    log_info "  patched trusty build.py: forced nice=\"\""
}

# 3. Even with nsjail working, the Trusty TEE-VM build for the custom Rust
#    target `x86_64-unknown-trusty-kernel` fails with E0463 ("can't find
#    crate for `core`") because prebuilts/rust ships no precompiled `core`
#    rlib for that target. The Soong genrules in
#    trusty/vendor/google/aosp/scripts/Android.bp are not on our critical
#    path -- they produce TEE simulator VMs only used by Cuttlefish for
#    trusted-HAL emulation, which we do not exercise. Replace their shared
#    cmd template with a stub that emits an ELF-magic-prefixed marker
#    file. Soong's dependency graph stays intact; the rest of the build
#    proceeds.
patch_trusty_stub_genrules() {
    local script="/opt/pipeline/hooks/files/stub-trusty-genrules.py"
    local bp="${SRC_DIR}/trusty/vendor/google/aosp/scripts/Android.bp"

    [[ -f "$bp" ]] || return 0
    [[ -x "$script" ]] || { log_warn "  $script missing/not executable"; return 0; }

    if grep -q "MAYAOS_TRUSTY_STUB" "$bp"; then
        log_info "  trusty genrules already stubbed, skipping"
        return 0
    fi

    if python3 "$script" "$bp"; then
        log_info "  patched trusty Android.bp: VM genrules emit stub ELF"
    else
        log_warn "  failed to stub trusty genrules; build may fail at trusty_security_vm_*.elf"
    fi
}

# 4. Cuttlefish's vsoc_<arch> products auto-generate ro.product.<partition>.{device,name}
#    from TARGET_DEVICE / TARGET_PRODUCT, and bake ro.product.first_api_level=37
#    into PRODUCT_VENDOR_PROPERTIES. Our MayaOS device tree spoofs all three to
#    Samsung-flavored values via PRODUCT_PROPERTY_OVERRIDES. AOSP's
#    post_process_props rejects duplicate sysprop assignments by default, so
#    enable BUILD_BROKEN_DUP_SYSPROP at the BoardConfig level for EVERY board
#    a MayaOS profile lunches. With --allow-dup, duplicates are written to
#    build.prop in source order; Android init's last-write-wins behavior at
#    runtime then resolves to our overrides.
patch_board_dup_sysprop() {
    local marker="# mayaos: BUILD_BROKEN_DUP_SYSPROP for sysprop spoofing"
    # Each MayaOS profile inherits from one of these vsoc_<arch> boards.
    # Add new ones here when introducing a new lunch target architecture.
    local boards=(
        "${SRC_DIR}/device/google/cuttlefish/vsoc_x86_64/BoardConfig.mk"
        "${SRC_DIR}/device/google/cuttlefish/vsoc_arm64/BoardConfig.mk"
        "${SRC_DIR}/device/google/cuttlefish/vsoc_x86/BoardConfig.mk"
        "${SRC_DIR}/device/google/cuttlefish/vsoc_riscv64/BoardConfig.mk"
    )

    local bc patched=0 skipped=0 missing=0
    for bc in "${boards[@]}"; do
        if [[ ! -f "$bc" ]]; then
            missing=$((missing + 1))
            continue
        fi
        if grep -qF "$marker" "$bc"; then
            log_info "  $(basename "$(dirname "$bc")")/BoardConfig.mk already has BUILD_BROKEN_DUP_SYSPROP, skipping"
            skipped=$((skipped + 1))
            continue
        fi
        {
            printf '\n%s\n' "$marker"
            printf '%s\n' 'BUILD_BROKEN_DUP_SYSPROP := true'
        } >> "$bc"
        log_info "  patched $(basename "$(dirname "$bc")")/BoardConfig.mk: BUILD_BROKEN_DUP_SYSPROP := true"
        patched=$((patched + 1))
    done

    log_info "  dup-sysprop summary: patched=${patched} already=${skipped} not-present=${missing}"
}

log_info "after-sync: applying container-env workarounds"
maybe_install_fakejail
patch_trusty_no_nice
patch_trusty_stub_genrules
patch_board_dup_sysprop

log_info "after-sync: ok"
