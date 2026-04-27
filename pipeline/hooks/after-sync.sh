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

log_info "after-sync: ok"
