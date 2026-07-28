#!/bin/bash
# Run on the VPS after a checkout of main (by the deploy-wireguard workflow's
# self-hosted runner). Applies any pinned version bump to the root
# (WireGuard) compose stack only.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR/.." || exit

./wireguard.sh update --yes
status=$?

docker image prune -f

exit $status
