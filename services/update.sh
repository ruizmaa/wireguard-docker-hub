#!/bin/bash
# Updates the services (adguard/syncthing/jellyfin) compose stack images.
# Run manually, or via scripts/deploy-services.sh in the deploy-services workflow.
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/update-images.sh
source "$SCRIPT_DIR/../scripts/lib/update-images.sh"

update_compose_images "$SCRIPT_DIR/docker-compose.yml" "$1"
