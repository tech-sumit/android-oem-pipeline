#!/usr/bin/env bash
# Bring up / down a local cloudflared for testing without going through
# Terraform. Useful when iterating on STF auth + Access policies.
#
# Usage:
#   ACTION=up   TUNNEL_TOKEN=<...> ./mdf/scripts/mdf-cloudflared.sh
#   ACTION=down ./mdf/scripts/mdf-cloudflared.sh

set -euo pipefail

ACTION="${ACTION:-up}"
NAME="${NAME:-mdf-local}"

case "$ACTION" in
    up)
        if [ -z "${TUNNEL_TOKEN:-}" ]; then
            echo "FAIL: TUNNEL_TOKEN required"; exit 1
        fi
        docker rm -f "$NAME" 2>/dev/null || true
        docker run -d --name "$NAME" --restart unless-stopped \
            --network host \
            cloudflare/cloudflared:latest \
            tunnel --no-autoupdate run --token "$TUNNEL_TOKEN"
        echo "==> cloudflared $NAME up"
        ;;
    down)
        docker rm -f "$NAME" 2>/dev/null || true
        echo "==> cloudflared $NAME down"
        ;;
    *)
        echo "FAIL: ACTION must be up|down"; exit 1
        ;;
esac
