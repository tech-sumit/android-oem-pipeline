#!/usr/bin/env bash
#
# Phase 3: after repo sync, before lunch.
#
# Splices the MayaOS Waydroid-style layered tree into the freshly synced
# AOSP source. Three layers, three mounts:
#
#   /srv/aosp-tree/device/mayaos/    -> $SRC_DIR/device/mayaos/
#   /srv/aosp-tree/hardware/mayaos/  -> $SRC_DIR/hardware/mayaos/
#   /srv/aosp-tree/vendor/mayaos/    -> $SRC_DIR/vendor/mayaos/
#   /srv/aosp-tree/packages/apps/MayaOSUpdater/ (if present)
#                                    -> $SRC_DIR/packages/apps/MayaOSUpdater/
#
# /srv/aosp-tree (host bind mount) is treated as authoritative -- we wipe the
# splice targets and copy fresh on every build so a `git status` inside AOSP
# is always clean except for our overlay.
#
# Then stages every CA in /srv/cacerts into vendor/mayaos/rootdir/system/etc/
# security/cacerts/ with the Android-style hashed filename. (Rev 5: CAs live
# on the vendor partition, see plan §3 decision (d).)
#
set -Eeuo pipefail
# shellcheck source=../lib.sh
source "/opt/pipeline/lib.sh"

# ---- Paths -----------------------------------------------------------------
AOSPTREE_DIR="${AOSPTREE_DIR:-/srv/aosp-tree}"

splice_layer() {
    local layer="$1"   # "device" | "hardware" | "vendor"
    local src="${AOSPTREE_DIR}/${layer}/mayaos"
    local dst="${SRC_DIR}/${layer}/mayaos"

    if [[ ! -d "$src" ]]; then
        log_info "  layer ${layer}: no ${src} present, skipping"
        return 0
    fi

    rm -rf "$dst"
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    log_info "  layer ${layer}: spliced ${src} -> ${dst}"
}

splice_packages_apps() {
    local src="${AOSPTREE_DIR}/packages/apps"
    local dst="${SRC_DIR}/packages/apps"

    [[ -d "$src" ]] || { log_info "  packages/apps: nothing to splice"; return 0; }

    shopt -s nullglob
    for app_dir in "$src"/*/; do
        local app_name
        app_name="$(basename "$app_dir")"
        local app_dst="${dst}/${app_name}"
        rm -rf "$app_dst"
        mkdir -p "$dst"
        cp -a "$app_dir" "$app_dst"
        log_info "  packages/apps/${app_name}: spliced"
    done
    shopt -u nullglob
}

# ---- Splice the 3+1 layers ------------------------------------------------
log_info "after-sync: splicing MayaOS Waydroid-style layered tree into AOSP source"

if [[ ! -d "$AOSPTREE_DIR" ]]; then
    log_error "expected ${AOSPTREE_DIR} to be bind-mounted; not found"
    exit 1
fi

splice_layer device
splice_layer hardware
splice_layer vendor
splice_packages_apps

# ---- Stage CAs into vendor/mayaos/rootdir/.../cacerts ---------------------
# A single shared dir on the vendor partition (one entry per CA, picked up
# by vendor/mayaos/product.mk's PRODUCT_COPY_FILES wildcard).
stage_ca_certs() {
    local cacert_dst="${SRC_DIR}/vendor/mayaos/rootdir/system/etc/security/cacerts"
    mkdir -p "$cacert_dst"

    shopt -s nullglob
    local ca_count=0

    for pem in "$CACERTS_DIR"/*.pem; do
        local fname
        fname="$(cert_hash_filename "$pem")"
        cp "$pem" "${cacert_dst}/${fname}"
        ca_count=$((ca_count + 1))
        log_info "  staged $(basename "$pem") -> ${cacert_dst#"$SRC_DIR/"}/${fname}"
    done

    for hashed in "$CACERTS_DIR"/*.0; do
        cp "$hashed" "${cacert_dst}/$(basename "$hashed")"
        ca_count=$((ca_count + 1))
        log_info "  staged $(basename "$hashed") (pre-hashed)"
    done
    shopt -u nullglob

    if [[ "$ca_count" -eq 0 ]]; then
        log_warn "no CAs found in ${CACERTS_DIR}; builds use whatever is committed"
    else
        log_info "  staged ${ca_count} CA cert(s) into ${cacert_dst#"$SRC_DIR/"}/"
    fi
}

stage_ca_certs

# ---- Sanity: at least one AndroidProducts.mk must be visible --------------
if ! find "${SRC_DIR}/device/mayaos" -maxdepth 3 -name AndroidProducts.mk \
        | grep -q .; then
    log_error "no AndroidProducts.mk found under device/mayaos/; aborting"
    exit 1
fi

# ---- Container-environment workarounds for Android 16 (trunk_staging) -----
# Most managed Docker hosts (RunPod / Vast / GitHub Actions / GitLab Cloud)
# strip CAP_SYS_ADMIN from the container and the kernel then rejects every
# CLONE_NEW* flag. AOSP's `nsjail`-wrapped genrules can't run there, and a
# few specific genrules (notably `trusty_security_vm_*.elf`) fail outright.

# 1. Replace the prebuilt nsjail with a Python "fakejail".
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

# 2. Trusty's build.py invokes `nice` unconditionally unless `--no-nice`.
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

# 3. Trusty TEE-VM genrules need a stub for the missing rust core rlib.
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

# 4. BUILD_BROKEN_DUP_SYSPROP. Rev 5 keeps this as a safety net for boards
# we haven't enumerated under vendor/mayaos/BoardConfigExtra.mk yet.
patch_board_dup_sysprop() {
    local marker="# mayaos: BUILD_BROKEN_DUP_SYSPROP for sysprop spoofing"
    # Each MayaOS profile inherits from one of these boards.
    #   vsoc_*  -- cuttlefish profiles (mayaos_cf_s26ultra*)
    #   emu*    -- AOSP SDK phone targets used by the emulator profiles
    local boards=(
        "${SRC_DIR}/device/google/cuttlefish/vsoc_x86_64/BoardConfig.mk"
        "${SRC_DIR}/device/google/cuttlefish/vsoc_arm64/BoardConfig.mk"
        "${SRC_DIR}/device/google/cuttlefish/vsoc_x86/BoardConfig.mk"
        "${SRC_DIR}/device/google/cuttlefish/vsoc_riscv64/BoardConfig.mk"
        "${SRC_DIR}/build/make/target/board/emu64a/BoardConfig.mk"
        "${SRC_DIR}/build/make/target/board/emu64x/BoardConfig.mk"
        "${SRC_DIR}/build/make/target/board/emu64x32/BoardConfig.mk"
        "${SRC_DIR}/build/make/target/board/emu64r/BoardConfig.mk"
        "${SRC_DIR}/device/generic/goldfish/board/BoardConfig.mk"
        "${SRC_DIR}/device/generic/arm64/BoardConfig.mk"
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
