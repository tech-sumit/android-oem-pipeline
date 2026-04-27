#!/usr/bin/env bash
# Open an interactive SSH session into the active Vast.ai instance.
# Pass-through extra args, e.g.:
#   ./vast/ssh.sh                 # interactive shell
#   ./vast/ssh.sh 'docker ps'     # one-shot remote command
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_vastai_auth
ssh_into_instance "$@"
