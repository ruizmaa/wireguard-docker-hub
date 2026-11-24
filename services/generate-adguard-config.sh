#!/bin/bash
# Generates services/adguard/conf/AdGuardHome.yaml with a real admin password hash.
# Usage: ./services/generate-adguard-config.sh [--force]
# Non-interactive (e.g. CI): set ADGUARD_SETUP_USER and ADGUARD_SETUP_PASSWORD.
set -eo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"
# shellcheck source=scripts/lib/writable-guard.sh
source "$SCRIPT_DIR/../scripts/lib/writable-guard.sh"
# shellcheck source=scripts/lib/force-flag.sh
source "$SCRIPT_DIR/../scripts/lib/force-flag.sh"
# shellcheck source=scripts/lib/adguard-users.sh
source "$SCRIPT_DIR/../scripts/lib/adguard-users.sh"
# shellcheck source=scripts/lib/restart-guard.sh
source "$SCRIPT_DIR/../scripts/lib/restart-guard.sh"
# shellcheck source=scripts/lib/adguard-rewrites.sh
source "$SCRIPT_DIR/../scripts/lib/adguard-rewrites.sh"

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# Fails clearly here if .env is incomplete, not with a cryptic docker error later
if ! compose_json=$(docker compose -f "$COMPOSE_FILE" config --format json); then
    echo -e "${RED}Error: 'docker compose config' failed. Check .env is fully filled in.${NC}"
    exit 1
fi
IMAGE=$(echo "$compose_json" | jq -r '.services.adguard.image')

OUT_DIR="$SCRIPT_DIR/adguard/conf"
OUT_FILE="$OUT_DIR/AdGuardHome.yaml"
TEMPLATE_FILE="$SCRIPT_DIR/adguard/AdGuardHome.yaml.template"
# Also created so docker compose up doesn't create it as root first
WORK_DIR="$SCRIPT_DIR/adguard/work"

parse_force_flag "$@"

guard_writable_dir "$OUT_DIR"
guard_writable_dir "$WORK_DIR"
guard_writable_file "$OUT_FILE"

# Refuse to overwrite an existing config unless the caller explicitly opted in
refuse_overwrite_without_force "$OUT_FILE"

# The template is tracked in git and should always exist, if not raise an error
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo -e "${RED}Error: $TEMPLATE_FILE is missing.${NC}"
    exit 1
fi

# With more than one admin account, they'd all get overwritten with the same one
admin_count=$(count_admin_accounts < "$TEMPLATE_FILE")
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

# Split-horizon DNS for *.home.arpa (see SERVICES.md), only if nginx is in this deployment.
load_rewrite_subnets "$compose_json"
USER_RULES_BLOCK=""

# LAN_SUBNET is only set on nginx's environment block, so its presence means nginx is deployed
# This whole block only fills in USER_RULES_BLOCK
if [ -n "$LAN_SUBNET" ]; then

    # One <name>.home.arpa per conf.d/ template, pointed at this host's LAN and VPN IPs
    load_service_hosts "$SCRIPT_DIR/nginx/templates/conf.d"
    detect_rewrite_ips

    # Rebuilds the template's user_rules: with them, keeping every other custom rule as-is
    compute_user_rules "$TEMPLATE_FILE" || exit 1

    # Shows every nginx rule (new, changed, unchanged, removed), then the custom ones kept
    echo "DNS rewrites for *.home.arpa (managed by nginx, split by zone):"
    printf '%s\n' "${REWRITE_REPORT[@]}"
    if [ "${#KEPT_RULES[@]}" -gt 0 ]; then
        echo "Other existing custom rules, kept as-is:"
        printf '    %s\n' "${KEPT_RULES[@]}"
    fi

    # Ask for confirmation unless running non-interactively (CI sets both env vars)
    if [ -z "$ADGUARD_SETUP_USER" ] || [ -z "$ADGUARD_SETUP_PASSWORD" ]; then
        read -r -p "Apply these DNS rewrites? [y/N] " confirm_rewrites
        if [ "$confirm_rewrites" != "y" ] && [ "$confirm_rewrites" != "Y" ]; then
            echo "Aborted, nothing changed."
            exit 1
        fi
    fi
fi

# GENERATE CONFIG VIA THROWAWAY CONTAINER
# Unique per PID, so two runs at once don't collide on the container name
tmp_name="adguard-config-gen-$$"
# Runs on every exit path. Removes the throwaway container, and restarts adguard if this script stopped it
cleanup() {
    docker rm -f "$tmp_name" > /dev/null 2>&1 || true
    # AdGuard left down means no DNS on the LAN: fail even if the config was generated
    restart_service_if_was_running "$COMPOSE_FILE" adguard "$ADGUARD_WAS_RUNNING" || exit 1
}
trap cleanup EXIT

echo -e "${YELLOW}-> Starting a throwaway AdGuard container to generate the config...${NC}"
# Runs a real AdGuard so its own binary produces the password hash, not a reimplementation
docker run -d --name "$tmp_name" "$IMAGE" > /dev/null

# Polling until the container is ready
ready="false"
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

# Sets the admin account on the throwaway container, via AdGuard's own setup-wizard API
payload=$(jq -n --arg u "$admin_user" --arg p "$admin_password" \
    '{web: {ip: "0.0.0.0", port: 80}, dns: {ip: "0.0.0.0", port: 53}, username: $u, password: $p}')
response=$(docker exec "$tmp_name" wget -qO- \
    --header='Content-Type: application/json' \
    --post-data="$payload" \
    http://127.0.0.1:3000/control/install/configure)

if [ "$response" != "OK" ]; then
    echo -e "${RED}Error: the throwaway container's install API didn't confirm success (got: $response).${NC}"
    exit 1
fi

# The real adguard container only reads its config at startup
# It must be stopped for a regenerate to take effect
ADGUARD_WAS_RUNNING="false"
if [ "$FORCE" = "true" ]; then
    ADGUARD_WAS_RUNNING=$(stop_service_if_running "$COMPOSE_FILE" adguard "new config")
fi

# Create the confing and working (blocklists/query/log/stats) directories with your user
mkdir -p "$OUT_DIR" "$WORK_DIR"

# Read back the users block AdGuard itself wrote (with the real password hash)
users_live=$(docker exec "$tmp_name" cat /opt/adguardhome/conf/AdGuardHome.yaml | users_block)
if [ -z "$users_live" ]; then
    echo -e "${RED}Error: couldn't read the users: block back from the throwaway container.${NC}"
    exit 1
fi
# These 2 lines are all we need, the throwaway container itself is discarded on exit
name_line=$(printf '%s\n' "$users_live" | grep '^  - name:')
password_line=$(printf '%s\n' "$users_live" | grep '^    password:')

# The template has everything else (blocklists, filters...)
# Only account/password and the user_rules are computed dynamically and spliced in
# Substitution 1: swap the real name/password from above
AWK_PROGRAM='
/^users:/ { f = 1 }                              # entering the users: block
f && !/^users:/ && /^[^ ]/ { f = 0 }             # left it: next top-level key
f && /^  - name:/ { print ENVIRON["NAME_LINE"]; name_subs++; next }
f && /^    password:/ { print ENVIRON["PASSWORD_LINE"]; password_subs++; next }
'
if [ -n "$LAN_SUBNET" ]; then
    # Substitution 2: swap the whole user_rules: block for the one computed above
    AWK_PROGRAM="$AWK_PROGRAM$USER_RULES_SUBST_AWK"
fi

# Fails loudly if these substitutions stop matching anything
AWK_PROGRAM="$AWK_PROGRAM"'
{ print }
END {
    if (name_subs != 1 || password_subs != 1) {
        print "expected exactly 1 name/password substitution, got " name_subs "/" password_subs > "/dev/stderr"
        exit 1
    }
}
'

# Written to a temp file first: a failed --force regenerate must leave the live config alone,
OUT_TMP="$OUT_FILE.tmp"
if ! NAME_LINE="$name_line" PASSWORD_LINE="$password_line" USER_RULES_BLOCK="$USER_RULES_BLOCK" \
    awk "$AWK_PROGRAM" "$TEMPLATE_FILE" > "$OUT_TMP"; then
    echo -e "${RED}Error: couldn't substitute the admin name/password into $TEMPLATE_FILE. Its format may have changed.${NC}"
    rm -f "$OUT_TMP"
    exit 1
fi
# Owned by the real user even under sudo (e.g. --force), then mv for an atomic swap
chown "${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}" "$OUT_TMP"
mv "$OUT_TMP" "$OUT_FILE"

# Read/write for your user only
chmod 600 "$OUT_FILE"
echo -e "${GREEN}-> Generated $OUT_FILE from your tracked template, with a fresh password hash.${NC}"

# Restarting adguard (if this script stopped it) is handled by the cleanup trap above,

echo "   Upstream DNS and blocklists (see SERVICES.md) are still set from AdGuard's own web UI after it's up."
if [ -n "$LAN_SUBNET" ]; then
    echo "   DNS for *.home.arpa was set automatically above, for both LAN and VPN clients (nginx is in use)."
fi
echo "   Run ./services/snapshot-adguard-config.sh afterwards to track those changes in git (password redacted automatically)."
