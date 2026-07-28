#!/bin/bash
# Run on the home server after a checkout of main (by the deploy-services
# workflow's self-hosted runner). Applies any pinned version bump to the
# services (pihole/syncthing/jellyfin) compose stack only.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR/.." || exit

./services/update.sh --yes
status=$?

docker image prune -f

exit $status
