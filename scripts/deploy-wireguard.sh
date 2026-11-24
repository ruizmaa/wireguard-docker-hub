#!/bin/bash
# Run on the VPS after a checkout of main (by the deploy-wireguard workflow's
# self-hosted runner). Applies any pinned version bump to the root
# (WireGuard) compose stack, then reconciles any other compose drift
# (cap_add, volumes, env, etc.).

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/deploy-log.sh
source "$SCRIPT_DIR/lib/deploy-log.sh"
start_deploy_log "VPS"
cd "$SCRIPT_DIR/.." || exit

./wireguard.sh update --yes
status=$?

docker compose up -d --remove-orphans || status=1

docker image prune -f

exit $status
