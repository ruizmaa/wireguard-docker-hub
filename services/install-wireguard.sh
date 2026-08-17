#!/bin/bash
# Fetches a peer's WireGuard config from the VPS and installs/reloads it on the
# target (installing wireguard/resolvconf there first), instead of hand-editing
# wg0.conf. Run from a third device with SSH to both.
# Usage: ./services/install-wireguard.sh <target-ssh-host> <vps-ssh-host> <peer-name> [--dry-run] [--yes]
set -e

WG_CONF="/etc/wireguard/wg0.conf"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"

DRY_RUN="false"
AUTO_YES="false"
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="true" ;;
        --yes) AUTO_YES="true" ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
TARGET_HOST="${POSITIONAL[0]:-}"
VPS_HOST="${POSITIONAL[1]:-}"
PEER_NAME="${POSITIONAL[2]:-}"

if [ -z "$TARGET_HOST" ] || [ -z "$VPS_HOST" ] || [ -z "$PEER_NAME" ]; then
    echo "Usage: $0 <target-ssh-host> <vps-ssh-host> <peer-name> [--dry-run] [--yes]"
    exit 1
fi

# Never print PrivateKey/PresharedKey values to the terminal, even in a diff.
censor() {
    sed -E 's/^(PrivateKey|PresharedKey) = .*/\1 = <censored>/'
}

# Install packages in the target host
echo -e "    ${YELLOW}[1/4]${NC} Installing wireguard and resolvconf on $TARGET_HOST..."
ssh "$TARGET_HOST" "sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq > /dev/null"
ssh "$TARGET_HOST" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard resolvconf > /dev/null"

if ssh "$TARGET_HOST" "command -v wg > /dev/null && command -v wg-quick > /dev/null"; then
    echo -e "      ${GREEN}-> wg/wg-quick are available on $TARGET_HOST.${NC}"
else
    echo -e "      ${RED}-> Error: wireguard-tools verification failed on $TARGET_HOST.${NC}"
    exit 1
fi

if ssh "$TARGET_HOST" "dpkg -s resolvconf > /dev/null 2>&1"; then
    echo -e "      ${GREEN}-> resolvconf is installed on $TARGET_HOST.${NC}"
else
    echo -e "      ${RED}-> Error: resolvconf verification failed on $TARGET_HOST.${NC}"
    exit 1
fi

# Get the new config from the VPS
echo -e "    ${YELLOW}[2/4]${NC} Fetching peer config '$PEER_NAME' from $VPS_HOST..."
if ! new_conf=$(ssh "$VPS_HOST" "cd ~/wireguard-docker-hub && ./wireguard.sh conf-file $PEER_NAME"); then
    echo -e "      ${RED}-> Error: failed to fetch the peer config over SSH.${NC}"
    exit 1
fi

# Sanity check the content itself
if ! echo "$new_conf" | grep -q '^\[Interface\]'; then
    echo -e "      ${RED}-> Error: fetched content doesn't look like a WireGuard config:${NC}"
    echo "$new_conf"
    exit 1
fi
echo -e "      ${GREEN}-> Fetched.${NC}"

# Compare the new config with the current one on the target host
echo -e "    ${YELLOW}[3/4]${NC} Comparing with the config on $TARGET_HOST..."
current_conf=$(ssh "$TARGET_HOST" "sudo test -f $WG_CONF && sudo cat $WG_CONF" || true)

diff_output=$(diff <(echo "$current_conf") <(echo "$new_conf") || true)

# There is no difference, exit early and don't do anything, everything is OK
if [ -z "$diff_output" ]; then
    echo -e "      ${GREEN}-> Already up to date, nothing to do.${NC}"
    exit 0
fi

# Get the diff, but censor sensitive keys
censored_diff=$(diff <(echo "$current_conf" | censor) <(echo "$new_conf" | censor) || true)

# If the censored diff is not empty, print it
if [ -n "$censored_diff" ]; then
    echo "$censored_diff"
# If the censored diff is empty, it means only the sensitive keys changed, so we print a message instead of the diff
else
    echo "      (only PrivateKey/PresharedKey changed, they are censored, not shown)"
fi

# Exit early when --dry-run, no changes applied
if [ "$DRY_RUN" = "true" ]; then
    echo -e "      ${YELLOW}-> Dry run: no changes applied.${NC}"
    exit 0
fi

# Skipped entirely when --yes is passed
if [ "$AUTO_YES" != "true" ]; then
    read -r -p "      Apply this change to $TARGET_HOST:$WG_CONF? [y/N] " answer
    case "$answer" in
        [Yy]*) ;;
        *) echo "      Aborted."; exit 1 ;;
    esac
fi

# Apply the new configuration and reload the tunnel
echo -e "    ${YELLOW}[4/4]${NC} Applying and reloading the tunnel on $TARGET_HOST..."

# Back up if there was a previous conf to lose
if ssh "$TARGET_HOST" "sudo test -f $WG_CONF"; then
    backup="$WG_CONF.bak.$(date +%Y%m%d%H%M%S)"
    ssh "$TARGET_HOST" "sudo cp $WG_CONF $backup"
    echo -e "      ${GREEN}-> Backed up the previous config to $TARGET_HOST:$backup.${NC}"
fi

# $new_conf travels as piped stdin, not embedded in the command string, so the key never touches shell quoting
echo "$new_conf" | ssh "$TARGET_HOST" "sudo tee $WG_CONF > /dev/null"
ssh "$TARGET_HOST" "sudo chmod 600 $WG_CONF"

# restart reloads an already-running tunnel
if ssh "$TARGET_HOST" "systemctl is-enabled --quiet wg-quick@wg0"; then
    ssh "$TARGET_HOST" "sudo systemctl restart wg-quick@wg0"
    echo -e "      ${GREEN}-> Reloaded wg-quick@wg0 on $TARGET_HOST.${NC}"
# enable --now is only for the very first setup
else
    ssh "$TARGET_HOST" "sudo systemctl enable --now wg-quick@wg0"
    echo -e "      ${GREEN}-> Enabled and started wg-quick@wg0 on $TARGET_HOST.${NC}"
fi

# Verify the handshake on the target host
ssh "$TARGET_HOST" "sudo wg show wg0"
