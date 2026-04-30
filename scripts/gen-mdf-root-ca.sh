#!/usr/bin/env bash
#
# Generate the MayaOS Device Farm root CA (10-year RSA-4096).
#
# Two staging destinations:
#
#   1. ca/mdf-root-ca.pem
#      Commit this. Public material only.
#
#   2. aosp-tree/vendor/mayaos/rootdir/system/etc/security/cacerts/<hash>.0
#      Commit this. The wildcard in vendor/mayaos/product.mk picks it up
#      and bakes it into /system/etc/security/cacerts/ on the device.
#
# The PRIVATE key goes to:
#
#   3. ca/.private/mdf-root-ca.key
#      Gitignored. Push to Vault BEFORE deleting.
#
# The corresponding mitmproxy-on-pod uses this CA to mint per-host leaf
# certs at intercept time. Without the matching private key in Vault,
# mitmproxy can't sign anything, so the bake-only step is half the
# install -- you must complete the Vault push.
#
# Usage:
#   ./scripts/gen-mdf-root-ca.sh              # idempotent: skips if .pem exists
#   ./scripts/gen-mdf-root-ca.sh --force      # regenerate (rotates the CA)
#   ./scripts/gen-mdf-root-ca.sh --vault-only # skip generation; push existing .key
#
# Vault push (run after generation):
#   vault kv put secret/mdf/ca \
#       cert=@ca/mdf-root-ca.pem \
#       key=@ca/.private/mdf-root-ca.key \
#       hash=<the-hash-from-this-script>
#
# Plan reference: §3 decision (d) + Phase 3.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CA_DIR="${REPO_ROOT}/ca"
PRIVATE_DIR="${CA_DIR}/.private"
VENDOR_CACERTS="${REPO_ROOT}/aosp-tree/vendor/mayaos/rootdir/system/etc/security/cacerts"

PEM="${CA_DIR}/mdf-root-ca.pem"
KEY="${PRIVATE_DIR}/mdf-root-ca.key"

CN="MayaOS Device Farm Root CA"
SUBJECT="/C=IN/O=MayaOS/OU=Device Farm/CN=${CN}"
DAYS=3650

FORCE=0
VAULT_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --force)      FORCE=1 ;;
        --vault-only) VAULT_ONLY=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "$CA_DIR" "$PRIVATE_DIR" "$VENDOR_CACERTS"
chmod 700 "$PRIVATE_DIR"

if (( VAULT_ONLY )); then
    if [[ ! -f "$KEY" ]]; then
        echo "[gen-mdf-root-ca] --vault-only: $KEY missing; nothing to push" >&2
        exit 1
    fi
    echo "[gen-mdf-root-ca] PEM:  $PEM"
    echo "[gen-mdf-root-ca] KEY:  $KEY  (NOT committed)"
    echo
    echo "Push to Vault now:"
    HASH="$(openssl x509 -in "$PEM" -noout -subject_hash_old)"
    cat <<EOF
  vault kv put secret/mdf/ca \\
      cert=@${PEM#${REPO_ROOT}/} \\
      key=@${KEY#${REPO_ROOT}/} \\
      hash=${HASH}

After verifying the Vault entry:
  rm "$KEY"
  rmdir "$PRIVATE_DIR" 2>/dev/null || true

EOF
    exit 0
fi

if [[ -f "$PEM" && "$FORCE" -ne 1 ]]; then
    echo "[gen-mdf-root-ca] $PEM already exists; skipping."
    echo "  Use --force to regenerate (and rotate the CA)."
    exit 0
fi

echo "[gen-mdf-root-ca] generating ${DAYS}-day RSA-4096 root CA"
echo "  CN: ${CN}"
echo

openssl req -x509 -newkey rsa:4096 -nodes \
    -days "$DAYS" \
    -keyout "$KEY" \
    -out "$PEM" \
    -subj "$SUBJECT" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    2>&1 | tail -3

chmod 600 "$KEY"
chmod 644 "$PEM"

# Compute Android-style cert filename and stage into the vendor partition.
HASH="$(openssl x509 -in "$PEM" -noout -subject_hash_old)"
HASHED="${HASH}.0"

cp "$PEM" "${CA_DIR}/${HASHED}"
cp "$PEM" "${VENDOR_CACERTS}/${HASHED}"

echo
echo "--- cert summary ---"
openssl x509 -in "$PEM" -noout -subject -issuer -dates -fingerprint -sha256

echo
echo "[gen-mdf-root-ca] wrote:"
echo "  ${PEM}                            (commit this)"
echo "  ${CA_DIR}/${HASHED}               (commit this; Android-style filename)"
echo "  ${VENDOR_CACERTS}/${HASHED}       (commit this; baked into vendor partition)"
echo
echo "[gen-mdf-root-ca] private key (NOT committed):"
echo "  ${KEY}"
echo
echo "Next step: push to Vault:"
echo
cat <<EOF
  vault kv put secret/mdf/ca \\
      cert=@${PEM#${REPO_ROOT}/} \\
      key=@${KEY#${REPO_ROOT}/} \\
      hash=${HASH}

After verifying the Vault entry:
  rm "${KEY}"

EOF
