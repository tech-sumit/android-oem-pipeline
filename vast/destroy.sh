#!/usr/bin/env bash
#
# Stop billing on the active Vast.ai instance.
#
# By default we DESTROY the instance (--delete) so /workspace state is gone.
# Pass --stop to merely halt it (cheaper resume but you keep paying for disk).
#
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_vastai_auth

mode="${1:---destroy}"
id="$(current_instance_id)"

case "$mode" in
    --destroy|-d)
        log "destroying instance ${id} (this is permanent)"
        vastai destroy instance "$id"
        rm -f "$INSTANCE_FILE"
        log "removed ${INSTANCE_FILE}"
        ;;
    --stop|-s)
        log "stopping instance ${id} (still billed for disk)"
        vastai stop instance "$id"
        ;;
    *)
        die "usage: $0 [--destroy|--stop]"
        ;;
esac
