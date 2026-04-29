#!/usr/bin/env bash
# Open an interactive SSH session into the active RunPod pod.
# Pass-through extra args, e.g.:
#   ./runpod/ssh.sh                 # interactive shell
#   ./runpod/ssh.sh 'docker ps'     # one-shot remote command
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ensure_runpod_auth
ssh_into_pod "$@"
