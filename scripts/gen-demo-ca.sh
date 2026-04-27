#!/usr/bin/env bash
#
# Generate a self-signed demo root CA for first-run convenience. The PUBLIC
# PEM is staged into ca/ and into device-tree/.../security/cacerts/. The
# PRIVATE KEY is written next to it but is gitignored; you should delete it
# unless you intend to issue leaf certs from this demo CA.
#
# Usage:
#   ./scripts/gen-demo-ca.sh [-o ca/]
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-${REPO_ROOT}/ca}"
DEVICE_CACERTS="${REPO_ROOT}/device-tree/customos/customphone/security/cacerts"

mkdir -p "$OUT_DIR" "$DEVICE_CACERTS"
cd "$OUT_DIR"

KEY="customos-root-ca.key"
PEM="customos-root-ca.pem"

if [[ -f "$PEM" ]]; then
    echo "[gen-demo-ca] $OUT_DIR/$PEM already exists; not regenerating. Delete it first to force a new CA." >&2
    exit 0
fi

echo "[gen-demo-ca] generating 4096-bit RSA root CA, validity 10 years"
openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
    -keyout "$KEY" \
    -out "$PEM" \
    -subj '/C=IN/O=CustomOS/OU=Engineering/CN=CustomOS Root CA' 2>&1 | tail -5

echo
echo "--- cert info ---"
openssl x509 -in "$PEM" -noout -subject -issuer -dates -fingerprint -sha256

SUBJECT_HASH=$(openssl x509 -in "$PEM" -noout -subject_hash_old)
HASHED="${SUBJECT_HASH}.0"

cp "$PEM" "$HASHED"
cp "$PEM" "${DEVICE_CACERTS}/${HASHED}"

echo
echo "[gen-demo-ca] wrote:"
echo "  ${OUT_DIR}/${PEM}"
echo "  ${OUT_DIR}/${HASHED}                (Android-style filename)"
echo "  ${DEVICE_CACERTS}/${HASHED}         (staged into device tree)"
echo
echo "Private key: ${OUT_DIR}/${KEY}  (NOT committed; delete if you don't need it)"
