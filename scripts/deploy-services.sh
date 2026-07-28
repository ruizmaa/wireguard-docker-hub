#!/bin/bash
# Run on the home server after a checkout of main (by the deploy-services
# workflow's self-hosted runner). Applies any pinned version bump to the
# services (pihole/syncthing/jellyfin) compose stack, then reconciles any
# other compose drift (cap_add, ports, env, etc.).

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR/.." || exit

./services/update.sh --yes
status=$?

docker compose -f services/docker-compose.yml up -d || status=1

docker image prune -f

exit $status
