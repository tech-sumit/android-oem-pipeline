#!/usr/bin/env bash
#
# Add a real root CA to the build. Stages it into both ca/ (so it ships in
# git history) and device-tree/.../security/cacerts/ (so PRODUCT_COPY_FILES
# picks it up).
#
# Usage:
#   ./scripts/add-ca.sh /path/to/your-root.pem
#
# The input file must be a PEM-encoded X.509 certificate. We refuse to accept
# anything that contains a PRIVATE KEY block to prevent accidental commits.
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CA_DIR="${REPO_ROOT}/ca"
DEVICE_CACERTS="${REPO_ROOT}/device-tree/mayaos/galaxy-s26-ultra/security/cacerts"

src="${1:-}"
[[ -n "$src" && -f "$src" ]] || { echo "usage: $0 <path-to-pem>" >&2; exit 2; }

if grep -q -- '-----BEGIN .* PRIVATE KEY-----' "$src"; then
    echo "ERROR: $src contains a PRIVATE KEY block. Strip the key first; only public PEM is allowed." >&2
    exit 1
fi

if ! openssl x509 -in "$src" -noout 2>/dev/null; then
    echo "ERROR: $src is not a valid PEM-encoded X.509 certificate." >&2
    exit 1
fi

mkdir -p "$CA_DIR" "$DEVICE_CACERTS"

# Compute Android-style hashed filename.
hash=$(openssl x509 -in "$src" -noout -subject_hash_old)
hashed="${hash}.0"

# Idempotent: warn if an existing CA shares the same hash.
if [[ -f "${DEVICE_CACERTS}/${hashed}" ]]; then
    if cmp -s "$src" "${DEVICE_CACERTS}/${hashed}"; then
        echo "[add-ca] ${hashed} already present (identical content); nothing to do."
        exit 0
    fi
    echo "WARNING: ${DEVICE_CACERTS}/${hashed} exists with different content. Overwriting." >&2
fi

# Use the certificate's CN as a friendly stem for the staged-into-ca/ filename.
cn=$(openssl x509 -in "$src" -noout -subject -nameopt RFC2253 \
     | sed -n 's/.*CN=\([^,]*\).*/\1/p' | tr ' /\\:' '_____')
[[ -n "$cn" ]] || cn="root-ca"

cp "$src" "${CA_DIR}/${cn}.pem"
cp "$src" "${CA_DIR}/${hashed}"
cp "$src" "${DEVICE_CACERTS}/${hashed}"

echo "[add-ca] staged:"
echo "  ${CA_DIR}/${cn}.pem"
echo "  ${CA_DIR}/${hashed}"
echo "  ${DEVICE_CACERTS}/${hashed}"
echo
echo "Cert summary:"
openssl x509 -in "$src" -noout -subject -issuer -dates -fingerprint -sha256
echo
echo "Don't forget to git add + commit the new files."
