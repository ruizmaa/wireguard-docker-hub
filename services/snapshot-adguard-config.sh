#!/bin/bash
# Copies the live services/adguard/conf/AdGuardHome.yaml into the tracked
# adguard/AdGuardHome.yaml.template, with the username/password replaced by
# placeholders so neither reaches git.
# Usage: ./services/snapshot-adguard-config.sh
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"
# shellcheck source=scripts/lib/adguard-users.sh
source "$SCRIPT_DIR/../scripts/lib/adguard-users.sh"

LIVE_FILE="$SCRIPT_DIR/adguard/conf/AdGuardHome.yaml"
TEMPLATE_FILE="$SCRIPT_DIR/adguard/AdGuardHome.yaml.template"
NAME_PLACEHOLDER='  - name: "CENSURED: run generate-adguard-config.sh to set a real one"'
PASSWORD_PLACEHOLDER='    password: "CENSURED: run generate-adguard-config.sh to set a real one"'

# Nothing to snapshot without a live config generated first
if [ ! -f "$LIVE_FILE" ]; then
    echo -e "${RED}Error: $LIVE_FILE doesn't exist yet. Run generate-adguard-config.sh and start the stack first.${NC}"
    exit 1
fi

# With more than one user, the sed below would redact them all into the same placeholder
admin_count=$(count_admin_accounts < "$LIVE_FILE")
if [ "$admin_count" -ne 1 ]; then
    echo -e "${RED}Error: $LIVE_FILE has $admin_count admin accounts; this script only supports redacting exactly one.${NC}"
    echo "Redacting all of them isn't safe to automate blindly, and leaving extras unredacted would leak a real password hash into git."
    exit 1
fi

# Start from the live config, then redact the credentials below
cp "$LIVE_FILE" "$TEMPLATE_FILE"
# Only one admin account exists (checked above), so this replace is safe
sed -i "s|^  - name:.*|$NAME_PLACEHOLDER|; s|^    password:.*|$PASSWORD_PLACEHOLDER|" "$TEMPLATE_FILE"

echo -e "${GREEN}-> Wrote $TEMPLATE_FILE, with the username/password redacted.${NC}"
echo "   Review the diff, then git add/commit it yourself."
