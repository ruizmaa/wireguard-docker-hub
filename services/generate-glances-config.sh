#!/bin/bash
# Generates services/glances/<username>.pwd, the hashed password Glances' web server checks
# HTTP Basic Auth against. Reads GLANCES_USERNAME and GLANCES_PASSWORD straight out of .env (via
# docker compose config) so there's a single source of truth, also used by the glances service's
# -u flag and Homepage's widget -- set them in .env before running this.
# Usage: ./services/generate-glances-config.sh [--force]
set -eo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"
# shellcheck source=scripts/lib/writable-guard.sh
source "$SCRIPT_DIR/../scripts/lib/writable-guard.sh"
# shellcheck source=scripts/lib/force-flag.sh
source "$SCRIPT_DIR/../scripts/lib/force-flag.sh"

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"  # queried below to resolve .env values

# Fails clearly here if .env is incomplete, not with a cryptic docker error later
if ! compose_json=$(docker compose -f "$COMPOSE_FILE" config --format json); then
    echo -e "${RED}Error: 'docker compose config' failed. Check .env is fully filled in.${NC}"
    exit 1
fi

IMAGE=$(echo "$compose_json" | jq -r '.services.glances.image')
# Same values the glances service passes to -u and homepage substitutes into widgets.yaml
USERNAME=$(echo "$compose_json" | jq -r '.services.homepage.environment.HOMEPAGE_VAR_GLANCES_USERNAME')
PASSWORD=$(echo "$compose_json" | jq -r '.services.homepage.environment.HOMEPAGE_VAR_GLANCES_PASSWORD')

# The password has no default (unlike username), so it must be set
if [ -z "$PASSWORD" ]; then
    echo -e "${RED}Error: GLANCES_PASSWORD is empty in .env. Set it, then re-run this script.${NC}"
    exit 1
fi

OUT_DIR="$SCRIPT_DIR/glances"  # mounted into the glances container, see docker-compose.yml
OUT_FILE="$OUT_DIR/$USERNAME.pwd"  # filename Glances itself expects: <username>.pwd

parse_force_flag "$@"

guard_writable_dir "$OUT_DIR"
guard_writable_file "$OUT_FILE"

# Refuse to overwrite an existing password unless the caller explicitly opted in
refuse_overwrite_without_force "$OUT_FILE"

# The real glances container only reads its password file at startup
# It must be stopped for a regenerate to take effect
GLANCES_WAS_RUNNING="false"
cleanup() {
    if [ "$GLANCES_WAS_RUNNING" = "true" ]; then
        echo -e "${YELLOW}-> Restarting glances...${NC}"
        docker compose -f "$COMPOSE_FILE" start glances || echo -e "${RED}Error: failed to restart glances. Start it manually with 'docker compose start glances'.${NC}"
    fi
}
trap cleanup EXIT

# Get glances' container ID, if it's currently running, to know whether to stop/restart it below
if ! glances_id=$(docker compose -f "$COMPOSE_FILE" ps -q glances); then
    echo -e "${RED}Error: 'docker compose ps' failed. Check .env is fully filled in.${NC}"
    exit 1
fi

# It's running: stop it now, and flag it so cleanup() restarts it once the new file is written
if [ -n "$glances_id" ]; then
    GLANCES_WAS_RUNNING="true"
    echo -e "${YELLOW}-> Stopping the running glances container so the new password takes effect...${NC}"
    docker compose -f "$COMPOSE_FILE" stop glances
fi

echo -e "${YELLOW}-> Hashing the password with Glances' own binary (not a reimplementation)...${NC}"
# Uses Glances' own hashing code
hashed_password=$(docker run --rm "$IMAGE" python3 -c "
import sys
from glances.password import GlancesPassword
gp = GlancesPassword(username=sys.argv[2])
print(gp.hash_password(gp.get_hash(sys.argv[1])))
" "$PASSWORD" "$USERNAME")

# Don't write an empty/corrupt .pwd if docker run "succeeded" but printed nothing
if [ -z "$hashed_password" ]; then
    echo -e "${RED}Error: couldn't compute the password hash.${NC}"
    exit 1
fi

# Write the hash to disk, exact bytes (no trailing newline)
mkdir -p "$OUT_DIR"
printf '%s' "$hashed_password" > "$OUT_FILE"
# Read/write for your user only
chmod 600 "$OUT_FILE"

echo -e "${GREEN}-> Generated $OUT_FILE.${NC}"
echo "   Username is '$USERNAME'. Restarting (handled above if it was running) picks up the new password."
