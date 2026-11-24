#!/bin/bash
# Syncs only the *.home.arpa rewrites in the live AdGuardHome.yaml with nginx's conf.d/ templates, keeping everything else.
# No flags or prompts, so deploy-services.sh can run it unattended.
# Usage: ./services/sync-adguard-rewrites.sh
set -eo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"
# shellcheck source=scripts/lib/writable-guard.sh
source "$SCRIPT_DIR/../scripts/lib/writable-guard.sh"
# shellcheck source=scripts/lib/restart-guard.sh
source "$SCRIPT_DIR/../scripts/lib/restart-guard.sh"
# shellcheck source=scripts/lib/adguard-rewrites.sh
source "$SCRIPT_DIR/../scripts/lib/adguard-rewrites.sh"

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
LIVE_DIR="$SCRIPT_DIR/adguard/conf"
LIVE_FILE="$LIVE_DIR/AdGuardHome.yaml"

# No options on purpose, a typo'd flag must fail, not silently run
if [ "$#" -ne 0 ]; then
    echo -e "${RED}Error: sync-adguard-rewrites.sh takes no arguments (got: $*).${NC}"
    exit 1
fi

# Fails clearly here if .env is incomplete, not with a cryptic docker error later
if ! compose_json=$(docker compose -f "$COMPOSE_FILE" config --format json); then
    echo -e "${RED}Error: 'docker compose config' failed. Check .env is fully filled in.${NC}"
    exit 1
fi

# LAN_SUBNET is only set on nginx's environment block, so its absence means there's no nginx to point names at
load_rewrite_subnets "$compose_json"
if [ -z "$LAN_SUBNET" ]; then
    echo "-> nginx isn't part of this deployment, no *.home.arpa rewrites to sync."
    exit 0
fi

# AdGuard not set up yet: nothing lost, generate-adguard-config.sh writes every rule when it runs
if [ ! -f "$LIVE_FILE" ]; then
    echo -e "${YELLOW}-> AdGuard isn't set up yet (no $LIVE_FILE), nothing to sync. Run generate-adguard-config.sh to set it up.${NC}"
    exit 0
fi

# Fails clearly if Docker created the conf dir/file as root before generate-adguard-config.sh ran
guard_writable_dir "$LIVE_DIR"
guard_writable_file "$LIVE_FILE"

# The new file replaces the old one, so it must end up with the same owner AdGuard (user: in compose) runs as
if [ "$(id -u)" -ne 0 ] && [ "$(stat -c %u "$LIVE_FILE")" != "$(id -u)" ]; then
    echo -e "${RED}Error: $LIVE_FILE is owned by UID $(stat -c %u "$LIVE_FILE"), not you. Run this as that user, or with sudo.${NC}"
    exit 1
fi

# One <name>.home.arpa per conf.d/ template, pointed at this host's LAN and VPN IPs
load_service_hosts "$SCRIPT_DIR/nginx/templates/conf.d"
detect_rewrite_ips

# The user_rules: wanted now, compared against the live ones
compute_user_rules "$LIVE_FILE" || exit 1

# Possible leftovers (dropped service on an old IP...), or yours: kept, only listed for review
if [ "${#STALE_RULES[@]}" -gt 0 ]; then
    echo -e "${YELLOW}-> These kept *.home.arpa rules look like old nginx ones, remove any leftover in AdGuard (Filters > Custom rules):${NC}"
    printf '   %s\n' "${STALE_RULES[@]}"
fi

# Already in sync: exit without touching AdGuard
if [ "$REWRITES_CHANGED" != "true" ]; then
    echo -e "${GREEN}-> *.home.arpa rewrites already in sync (${#SERVICE_HOSTS[@]} hosts), AdGuard left untouched.${NC}"
    exit 0
fi

# Shows what's about to change before stopping AdGuard
echo "DNS rewrite changes for *.home.arpa (managed by nginx, split by zone):"
printf '%s\n' "${REWRITE_CHANGES[@]}"

# Runs on every exit path: drops a half-written temp file, restarts adguard if this script stopped it
ADGUARD_WAS_RUNNING="false"
OUT_TMP=""
cleanup() {
    [ -n "$OUT_TMP" ] && rm -f "$OUT_TMP"
    # AdGuard left down means no DNS on the LAN: fail so the deploy doesn't show green
    restart_service_if_was_running "$COMPOSE_FILE" adguard "$ADGUARD_WAS_RUNNING" || exit 1
}
trap cleanup EXIT

# AdGuard rewrites its own config while running, and only reads it at startup
ADGUARD_WAS_RUNNING=$(stop_service_if_running "$COMPOSE_FILE" adguard "DNS rewrite update")

# Recomputed now it's stopped, so a UI change saved since the read above isn't lost
compute_user_rules "$LIVE_FILE" || exit 1

# Written to a temp file first, then mv for an atomic swap: a failure here leaves the live config alone
OUT_TMP=$(mktemp "$LIVE_FILE.XXXXXX")
if ! USER_RULES_BLOCK="$USER_RULES_BLOCK" awk "$USER_RULES_SUBST_AWK"'
{ print }
END { if (user_rules_subs != 1) { print "expected exactly 1 user_rules: block, got " user_rules_subs + 0 > "/dev/stderr"; exit 1 } }
' "$LIVE_FILE" > "$OUT_TMP"; then
    echo -e "${RED}Error: couldn't rewrite the user_rules: block of $LIVE_FILE. Its format may have changed.${NC}"
    exit 1
fi
# Same mode as the file it replaces
chmod --reference="$LIVE_FILE" "$OUT_TMP"
# Under sudo the temp file is root's, hand it back to the live file's owner
[ "$(id -u)" -eq 0 ] && chown --reference="$LIVE_FILE" "$OUT_TMP"
mv "$OUT_TMP" "$LIVE_FILE"
OUT_TMP=""

# AdGuard itself is restarted by the cleanup trap, if it was running
echo -e "${GREEN}-> Synced the *.home.arpa rewrites into $LIVE_FILE.${NC}"
# Already stopped beforehand: not restarted, the new rules wait for its next start
if [ "$ADGUARD_WAS_RUNNING" != "true" ]; then
    echo "   AdGuard wasn't running, it picks them up next time it starts."
fi
