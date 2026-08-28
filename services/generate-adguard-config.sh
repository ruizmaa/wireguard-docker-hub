#!/bin/bash
# Generates services/adguard/conf/AdGuardHome.yaml with a real admin password hash.
# Usage: ./services/generate-adguard-config.sh [--force]
# Non-interactive (e.g. CI): set ADGUARD_SETUP_USER and ADGUARD_SETUP_PASSWORD.
set -eo pipefail

# Escapes `\` and `"` so a value is safe to embed in a JSON string below
json_escape() {
    local escaped="${1//\\/\\\\}"
    printf '%s' "${escaped//\"/\\\"}"
}

# Prints only the `users:` block, so no other list can be mistaken for it below
users_block() {
    awk '/^users:/{f=1} f && !/^users:/ && /^[^ ]/{exit} f'
}

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# Fails clearly here if .env is incomplete, not with a cryptic docker error later
if ! compose_json=$(docker compose -f "$COMPOSE_FILE" config --format json); then
    echo -e "${RED}Error: 'docker compose config' failed -- check .env is fully filled in.${NC}"
    exit 1
fi
IMAGE=$(echo "$compose_json" | jq -r '.services.adguard.image')

OUT_DIR="$SCRIPT_DIR/adguard/conf"
OUT_FILE="$OUT_DIR/AdGuardHome.yaml"
TEMPLATE_FILE="$SCRIPT_DIR/adguard/AdGuardHome.yaml.template"
# Also created so docker compose up doesn't create it as root first
WORK_DIR="$SCRIPT_DIR/adguard/work"

# Only --force is supported, any other flag is a typo and should fail loudly
FORCE="false"
for arg in "$@"; do
    case "$arg" in
        --force) FORCE="true" ;;
        *) echo "Error: unknown flag '$arg'"; exit 1 ;;
    esac
done

# Catches the root-owned-dir case before it reaches the container and fails confusingly
for dir in "$OUT_DIR" "$WORK_DIR"; do
    if [ -e "$dir" ] && { [ ! -d "$dir" ] || [ ! -w "$dir" ]; }; then
        echo -e "${RED}Error: $dir exists but isn't a writable directory.${NC}"
        echo "This usually means 'docker compose up' ran before this script and Docker auto-created it as root."
        echo "Fix it with: sudo chown -R \"\$(id -u):\$(id -g)\" \"$dir\""
        exit 1
    fi
done

# Also catches a stale root-owned config file left inside an otherwise-fixed dir (e.g. a partial chown without -R)
if [ -e "$OUT_FILE" ] && [ ! -w "$OUT_FILE" ]; then
    echo -e "${RED}Error: $OUT_FILE exists but isn't writable.${NC}"
    echo "This usually means 'docker compose up' ran before this script and Docker auto-created it as root."
    echo "Fix it with: sudo chown \"\$(id -u):\$(id -g)\" \"$OUT_FILE\""
    exit 1
fi

# Refuse to overwrite an existing config unless the caller explicitly opted in
if [ -f "$OUT_FILE" ] && [ "$FORCE" != "true" ]; then
    echo -e "${RED}Error: $OUT_FILE already exists. Pass --force to overwrite it.${NC}"
    exit 1
fi

# The template is tracked in git and should always exist, if not raise an error
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo -e "${RED}Error: $TEMPLATE_FILE is missing.${NC}"
    exit 1
fi

# With more than one admin account, they'd all get overwritten with the same one
# `|| true`: grep -c exits 1 on a zero count, which would otherwise kill the script
# here under set -e before the check below can print its own clearer error
admin_count=$(users_block < "$TEMPLATE_FILE" | grep -c '^  - name:' || true)
if [ "$admin_count" -ne 1 ]; then
    echo -e "${RED}Error: $TEMPLATE_FILE has $admin_count admin accounts; this script only supports managing exactly one.${NC}"
    echo "Edit the extra accounts in by hand after generating, or remove them from the template first."
    exit 1
fi

# Both env vars set (e.g. CI): use them directly, no prompts
if [ -n "$ADGUARD_SETUP_USER" ] && [ -n "$ADGUARD_SETUP_PASSWORD" ]; then
    admin_user="$ADGUARD_SETUP_USER"
    admin_password="$ADGUARD_SETUP_PASSWORD"
# Only one set: likely a typo'd var name, not a deliberate non-interactive run
elif [ -n "$ADGUARD_SETUP_USER" ] || [ -n "$ADGUARD_SETUP_PASSWORD" ]; then
    echo -e "${RED}Error: set both ADGUARD_SETUP_USER and ADGUARD_SETUP_PASSWORD, or neither (only one is set).${NC}"
    exit 1
# Neither set: fall back to interactive prompts
else
    read -r -p "AdGuard admin username: " admin_user
    read -r -s -p "AdGuard admin password: " admin_password
    echo
    read -r -s -p "Confirm password: " admin_password_confirm
    echo
    if [ "$admin_password" != "$admin_password_confirm" ]; then
        echo -e "${RED}Error: passwords didn't match.${NC}"
        exit 1
    fi
fi

# Empty username or password not allowed
if [ -z "$admin_user" ] || [ -z "$admin_password" ]; then
    echo "Error: username and password can't be empty."
    exit 1
fi

# AdGuard's own install API rejects anything shorter than 8 characters
if [ "${#admin_password}" -lt 8 ]; then
    echo "Error: password must be at least 8 characters (AdGuard's own requirement)."
    exit 1
fi

# Escape both so neither can break out of the JSON string below
json_user="$(json_escape "$admin_user")"
json_password="$(json_escape "$admin_password")"

# GENERATE CONFIG VIA THROWAWAY CONTAINER
# Unique per PID, so two runs at once don't collide on the container name
tmp_name="adguard-config-gen-$$"
# Always remove the throwaway container on exit, success or failure
cleanup() { docker rm -f "$tmp_name" > /dev/null 2>&1 || true; }
trap cleanup EXIT

echo -e "${YELLOW}-> Starting a throwaway AdGuard container to generate the config...${NC}"
# Runs a real AdGuard so its own binary produces the password hash, not a reimplementation
docker run -d --name "$tmp_name" "$IMAGE" > /dev/null

ready="false"
# Polling until the container is ready
for _ in $(seq 1 12); do
    if docker exec "$tmp_name" wget -qO /dev/null http://127.0.0.1:3000/ 2>/dev/null; then
        ready="true"
        break
    fi
    sleep 1
done
if [ "$ready" != "true" ]; then
    echo -e "${RED}Error: the throwaway container never became ready.${NC}"
    exit 1
fi

# Sets the admin account via AdGuard's own setup-wizard API
response=$(docker exec "$tmp_name" wget -qO- \
    --header='Content-Type: application/json' \
    --post-data="{\"web\":{\"ip\":\"0.0.0.0\",\"port\":80},\"dns\":{\"ip\":\"0.0.0.0\",\"port\":53},\"username\":\"$json_user\",\"password\":\"$json_password\"}" \
    http://127.0.0.1:3000/control/install/configure)

if [ "$response" != "OK" ]; then
    echo -e "${RED}Error: AdGuard's install API didn't confirm success (got: $response).${NC}"
    exit 1
fi

# AdGuard only reads its config at startup, so it must be stopped for a regenerate to take effect
ADGUARD_WAS_RUNNING="false"
if [ "$FORCE" = "true" ]; then
    if ! adguard_id=$(docker compose -f "$COMPOSE_FILE" ps -q adguard); then
        echo -e "${RED}Error: 'docker compose ps' failed -- check .env is fully filled in.${NC}"
        exit 1
    fi
    if [ -n "$adguard_id" ]; then
        ADGUARD_WAS_RUNNING="true"
        echo -e "${YELLOW}-> Stopping the running adguard container so the new config takes effect...${NC}"
        docker compose -f "$COMPOSE_FILE" stop adguard
    fi
fi

mkdir -p "$OUT_DIR" "$WORK_DIR"

# The container's own config is real, but throwaway: only these 2 lines get used below,
# the rest of it (and the container itself) is discarded when this script exits
users_live=$(docker exec "$tmp_name" cat /opt/adguardhome/conf/AdGuardHome.yaml | users_block)
if [ -z "$users_live" ]; then
    echo -e "${RED}Error: couldn't read the users: block back from the throwaway container.${NC}"
    exit 1
fi
name_line=$(printf '%s\n' "$users_live" | grep '^  - name:')
password_line=$(printf '%s\n' "$users_live" | grep '^    password:')

# The template has everything else (blocklists, rewrites...). Write it to $OUT_FILE,
# AdGuard's real config file, replacing placeholders with the real admin account/password from above
NAME_LINE="$name_line" PASSWORD_LINE="$password_line" awk '
/^users:/ { f = 1 }                              # entering the users: block
f && !/^users:/ && /^[^ ]/ { f = 0 }             # left it: next top-level key
f && /^  - name:/ { print ENVIRON["NAME_LINE"]; next }
f && /^    password:/ { print ENVIRON["PASSWORD_LINE"]; next }
{ print }
' "$TEMPLATE_FILE" > "$OUT_FILE"
echo -e "${GREEN}-> Generated $OUT_FILE from your tracked template, with a fresh password hash.${NC}"
# Read/write for your user only
chmod 600 "$OUT_FILE"

# Only restart it if this script was the one that stopped it above
if [ "$ADGUARD_WAS_RUNNING" = "true" ]; then
    echo -e "${YELLOW}-> Restarting adguard with the new config...${NC}"
    docker compose -f "$COMPOSE_FILE" start adguard
fi

echo "   Upstream DNS, blocklists and Local DNS Records (see SERVICES.md) are still set from AdGuard's own web UI after it's up."
echo "   Run ./services/snapshot-adguard-config.sh afterwards to track those changes in git (password redacted automatically)."
