#!/bin/bash
# Generates services/glances/<username>.pwd, the hashed password Glances' web server checks
# HTTP Basic Auth against. Reads GLANCES_USERNAME and GLANCES_PASSWORD straight out of .env, the
# same source of truth the glances service's -u flag and Homepage's widget use.
# Set them in .env before running this.
# Usage: ./services/generate-glances-config.sh [--force]
set -eo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"
# shellcheck source=scripts/lib/writable-guard.sh
source "$SCRIPT_DIR/../scripts/lib/writable-guard.sh"
# shellcheck source=scripts/lib/force-flag.sh
source "$SCRIPT_DIR/../scripts/lib/force-flag.sh"
# shellcheck source=scripts/lib/restart-guard.sh
source "$SCRIPT_DIR/../scripts/lib/restart-guard.sh"
# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/../scripts/lib/env.sh"

ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# Fails clearly here if .env is incomplete, not with a cryptic docker error later
if ! compose_json=$(docker compose -f "$COMPOSE_FILE" config --format json); then
    echo -e "${RED}Error: 'docker compose config' failed. Check .env is fully filled in.${NC}"
    exit 1
fi

IMAGE=$(echo "$compose_json" | jq -r '.services.glances.image')
USERNAME=$(read_env GLANCES_USERNAME glances)
PASSWORD=$(read_env GLANCES_PASSWORD)

# The password has no default (unlike username), so it must be set
if [ -z "$PASSWORD" ]; then
    echo -e "${RED}Error: GLANCES_PASSWORD is empty in .env. Set it, then re-run this script.${NC}"
    exit 1
fi

# Rejects invalid characters that would break paths or argument parsing
if [[ ! "$USERNAME" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo -e "${RED}Error: GLANCES_USERNAME ('$USERNAME') must contain only letters, digits, '.', '_' or '-'.${NC}"
    exit 1
fi

OUT_DIR="$SCRIPT_DIR/glances"  # mounted into the glances container, see docker-compose.yml
OUT_FILE="$OUT_DIR/$USERNAME.pwd"  # filename Glances itself expects: <username>.pwd

parse_force_flag "$@"

guard_writable_dir "$OUT_DIR"
guard_writable_file "$OUT_FILE"

# Refuse to overwrite an existing password unless the caller explicitly opted in
refuse_overwrite_without_force "$OUT_FILE"

GLANCES_WAS_RUNNING="false"
trap 'restart_service_if_was_running "$COMPOSE_FILE" glances "$GLANCES_WAS_RUNNING"' EXIT
if [ "$FORCE" = "true" ]; then  # on first setup there's nothing running yet to stop
    GLANCES_WAS_RUNNING=$(stop_service_if_running "$COMPOSE_FILE" glances "new password")
fi

echo -e "${YELLOW}-> Hashing the password with Glances' own binary (not a reimplementation)...${NC}"
# Uses Glances' own hashing code
hashed_password=$(printf '%s\n%s\n' "$PASSWORD" "$USERNAME" | docker run --rm -i "$IMAGE" python3 -c "
import sys
from glances.password import GlancesPassword
password, username = sys.stdin.read().splitlines()[:2]
gp = GlancesPassword(username=username)
print(gp.hash_password(gp.get_hash(password)))
")

# Don't write an empty/corrupt .pwd if docker run "succeeded" but printed nothing
if [ -z "$hashed_password" ]; then
    echo -e "${RED}Error: couldn't compute the password hash.${NC}"
    exit 1
fi

# Write the hash to disk
mkdir -p "$OUT_DIR"
OUT_TMP="$OUT_FILE.tmp"
printf '%s' "$hashed_password" > "$OUT_TMP"
chmod 600 "$OUT_TMP"
mv "$OUT_TMP" "$OUT_FILE"

echo -e "${GREEN}-> Generated $OUT_FILE.${NC}"
echo "   Username is '$USERNAME'. Restarting (handled above if it was running) picks up the new password."

# Homepage's widget reads these same .env values, baked in at container creation, so it needs recreating too.
echo -e "${YELLOW}-> Recreating homepage so its widget picks up the current .env values...${NC}"
docker compose -f "$COMPOSE_FILE" up -d --force-recreate homepage || echo -e "${RED}Error: failed to recreate homepage. Run 'docker compose up -d --force-recreate homepage' manually.${NC}"
