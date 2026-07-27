#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/update-images.sh
source "$SCRIPT_DIR/../scripts/lib/update-images.sh"

update_compose_images "$SCRIPT_DIR/docker-compose.yml" "$1"
