#!/usr/bin/env bash
# mdf-rotate-ca.sh -- rotate the MDF root CA.
#
# Generates a NEW root CA, leaves the OLD CA installed in the vendor
# trust store for a deprecation window (default 90 days), and pushes
# the new private key to Vault. After the deprecation window, run
# scripts/remove-ca.sh OLD_HASH and rebuild.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

NEW_PEM="ca/mdf-root-ca-$(date +%Y%m%d).pem"
NEW_KEY=".private/mdf-root-ca-$(date +%Y%m%d).key"
mkdir -p "ca/.private"

echo "==> generating fresh CA"
openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
    -keyout "ca/$NEW_KEY" \
    -out    "$NEW_PEM" \
    -subj   "/C=IN/O=MayaOS/OU=Device Farm/CN=MayaOS Device Farm Root CA $(date +%Y%m%d)"

HASH=$(openssl x509 -in "$NEW_PEM" -hash -noout)
cp "$NEW_PEM" "aosp-tree/vendor/mayaos/rootdir/system/etc/security/cacerts/${HASH}.0"

echo
echo "==> new CA written to:"
echo "    $NEW_PEM"
echo "    aosp-tree/vendor/mayaos/rootdir/system/etc/security/cacerts/${HASH}.0"
echo
echo "==> push the private key to Vault:"
echo "    vault kv put secret/mdf/ca-$(date +%Y%m%d) \\"
echo "        cert=@$NEW_PEM \\"
echo "        key=@ca/$NEW_KEY \\"
echo "        hash=$HASH"
echo
echo "    Then bump command-center/mdf-plugin-mitm to use the new key:"
echo "    MDF_MITM_CA_VAULT_PATH=secret/mdf/ca-$(date +%Y%m%d)"
echo
echo "==> the OLD CA stays in the trust store until you remove it via:"
echo "    bash scripts/remove-ca.sh <old-hash>.0"
