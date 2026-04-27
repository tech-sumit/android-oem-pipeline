#!/usr/bin/env bash
#
# Phase 3: after repo sync, before lunch.
#
# Splices our device tree into the freshly synced AOSP source, and copies
# every public CA in /srv/cacerts into device/customos/customphone/security/cacerts/
# with the Android-style hashed filename. This is the only phase that mutates
# the AOSP source itself; everything else either consumes or produces it.
#
# The device tree on /srv/devicetree (host bind mount) is treated as authoritative
# -- we wipe device/customos in the AOSP tree and copy fresh on every build so a
# `git status` inside AOSP is always clean except for our overlay.
#
set -Eeuo pipefail
# shellcheck source=../lib.sh
source "/opt/pipeline/lib.sh"

DEVICE_DST="${SRC_DIR}/device/customos"
CACERT_DST="${DEVICE_DST}/customphone/security/cacerts"

log_info "after-sync: splicing CustomOS device tree into AOSP source"

if [[ ! -d "$DEVICETREE_DIR/customos" ]]; then
    log_error "expected $DEVICETREE_DIR/customos to be bind-mounted; not found"
    exit 1
fi

# Refresh the device tree overlay.
rm -rf "$DEVICE_DST"
mkdir -p "$(dirname "$DEVICE_DST")"
cp -a "$DEVICETREE_DIR/customos" "$DEVICE_DST"
log_info "  copied $DEVICETREE_DIR/customos -> $DEVICE_DST"

# Re-stage CAs so /srv/cacerts is the single source of truth at runtime.
mkdir -p "$CACERT_DST"
shopt -s nullglob
ca_count=0
for pem in "$CACERTS_DIR"/*.pem; do
    fname="$(cert_hash_filename "$pem")"
    cp -v "$pem" "${CACERT_DST}/${fname}"
    ca_count=$((ca_count + 1))
done

# Also accept already-hashed certs (e.g. *.0 dropped in by gen-demo-ca.sh).
for hashed in "$CACERTS_DIR"/*.0; do
    cp -v "$hashed" "${CACERT_DST}/$(basename "$hashed")"
    ca_count=$((ca_count + 1))
done
shopt -u nullglob

if [[ "$ca_count" -eq 0 ]]; then
    log_warn "no CAs found in ${CACERTS_DIR}; build will use only the demo CA from device-tree"
else
    log_info "  staged ${ca_count} CA cert(s) into ${CACERT_DST}"
fi

# Sanity: the lunch combo must now be visible to the build system.
if ! find "${SRC_DIR}/device" -maxdepth 4 -name AndroidProducts.mk \
        -path '*customos*' | grep -q .; then
    log_error "AndroidProducts.mk for customos not found after splice; aborting"
    exit 1
fi

log_info "after-sync: ok"
