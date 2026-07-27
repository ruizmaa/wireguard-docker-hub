#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/../scripts/lib/update-images.sh"

update_compose_images "$SCRIPT_DIR/docker-compose.yml" "$1"
