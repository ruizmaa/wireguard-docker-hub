#!/bin/bash
# Generates services/adguard/conf/AdGuardHome.yaml with a real admin password hash.
# Usage: ./services/generate-adguard-config.sh [--force]
# Non-interactive (e.g. CI): set ADGUARD_SETUP_USER and ADGUARD_SETUP_PASSWORD.
set -e

IMAGE="adguard/adguardhome:v0.107.79"

# Escapes `\`, `&` and `|` so a value is safe to use as a sed replacement below
sed_escape_replacement() {
    printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'
}

# Escapes `\` and `"` so a value is safe to embed in a JSON string below
json_escape() {
    local escaped="${1//\\/\\\\}"
    printf '%s' "${escaped//\"/\\\"}"
}

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"

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
    if [ -e "$dir" ] && [ ! -w "$dir" ]; then
        echo -e "${RED}Error: $dir exists but isn't writable by you.${NC}"
        echo "This usually means 'docker compose up' ran before this script and Docker auto-created it as root."
        echo "Fix it with: sudo chown -R \"\$(id -u):\$(id -g)\" \"$dir\""
        exit 1
    fi
done

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
admin_count=$(grep -c '^  - name:' "$TEMPLATE_FILE")
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

mkdir -p "$OUT_DIR" "$WORK_DIR"

# The real credentials that will replace the template's placeholders below
name_line=$(docker exec "$tmp_name" grep '^  - name:' /opt/adguardhome/conf/AdGuardHome.yaml)
password_line=$(docker exec "$tmp_name" grep '^    password:' /opt/adguardhome/conf/AdGuardHome.yaml)
# Copy still has the censored placeholders, replaced below with the real ones
cp "$TEMPLATE_FILE" "$OUT_FILE"
# Only one admin account exists (checked above), so this replace is safe
sed -i "s|^  - name:.*|$(sed_escape_replacement "$name_line")|; s|^    password:.*|$(sed_escape_replacement "$password_line")|" "$OUT_FILE"
echo -e "${GREEN}-> Generated $OUT_FILE from your tracked template, with a fresh password hash.${NC}"
# Read/write for your user only
chmod 600 "$OUT_FILE"

echo "   Upstream DNS, blocklists and Local DNS Records (see SERVICES.md) are still set from AdGuard's own web UI after it's up."
echo "   Run ./services/snapshot-adguard-config.sh afterwards to track those changes in git (password redacted automatically)."
