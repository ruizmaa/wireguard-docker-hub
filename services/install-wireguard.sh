#!/bin/bash
# Fetches a peer's WireGuard config from the VPS and installs/reloads it on the
# target (installing wireguard/resolvconf there first), instead of hand-editing
# wg0.conf. Run from a third device with SSH to both.
# Usage: ./services/install-wireguard.sh <target-ssh-host> <vps-ssh-host> <peer-name> [--dry-run] [--yes]
# shellcheck disable=SC2029 # intentional: these vars are controller-side and must expand before ssh, not on the remote host
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

# Peer name ends up in a command string sent to the VPS over ssh, reject anything that
# isn't a plain name so it can't inject extra shell commands there
if [[ "$PEER_NAME" =~ [^[:alnum:]_-] ]]; then
    echo "Error: peer name must only contain letters, numbers, '_' or '-' (got: '$PEER_NAME')"
    exit 1
fi

# TARGET_HOST/VPS_HOST are passed straight to ssh, a leading "-" would be parsed as an
# ssh option instead of a destination, so reject that shape specifically
for host in "$TARGET_HOST" "$VPS_HOST"; do
    if [[ "$host" == -* ]]; then
        echo "Error: SSH host must not start with '-' (got: '$host')"
        exit 1
    fi
done

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

if ssh "$TARGET_HOST" "command -v resolvconf > /dev/null 2>&1"; then
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
# ssh exits 255 on a connection/auth failure, distinct from "sudo test -f" legitimately
# returning 1 because the file doesn't exist yet on a first install
if ssh "$TARGET_HOST" "sudo test -f $WG_CONF"; then
    if ! current_conf=$(ssh "$TARGET_HOST" "sudo cat $WG_CONF"); then
        echo -e "      ${RED}-> Error: failed to read the existing config on $TARGET_HOST.${NC}"
        exit 1
    fi
elif [ "$?" -eq 255 ]; then
    echo -e "      ${RED}-> Error: failed to SSH into $TARGET_HOST to check for an existing config.${NC}"
    exit 1
else
    current_conf=""
fi

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

# AllowedIPs is the one field operators are told to narrow by hand (see SERVICES.md)
# The VPS always sends its full-tunnel default back, so --yes must not silently reapply it over a local edit
current_allowedips=$(echo "$current_conf" | grep '^AllowedIPs' || true)
new_allowedips=$(echo "$new_conf" | grep '^AllowedIPs' || true)
allowedips_changed="false"
if [ -n "$current_conf" ] && [ "$current_allowedips" != "$new_allowedips" ]; then
    allowedips_changed="true"
fi

# Skipped entirely when --yes is passed, unless AllowedIPs itself changed
if [ "$AUTO_YES" != "true" ] || [ "$allowedips_changed" = "true" ]; then
    if [ "$allowedips_changed" = "true" ]; then
        echo -e "      ${YELLOW}-> Warning: AllowedIPs changed (was '${current_allowedips:-<none>}', now '${new_allowedips:-<none>}'). This overrides any manual narrowing done per SERVICES.md -- confirming even with --yes.${NC}"
    fi
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

# systemctl only reports that it failed, not why. The real error is in the journal
dump_wg_quick_journal() {
    ssh "$TARGET_HOST" "sudo journalctl -xeu wg-quick@wg0 --no-pager -n 50" || true
}

# restart reloads an already-running tunnel
if ssh "$TARGET_HOST" "systemctl is-enabled --quiet wg-quick@wg0"; then
    if ! ssh "$TARGET_HOST" "sudo systemctl restart wg-quick@wg0"; then
        echo -e "      ${RED}-> Error: failed to restart wg-quick@wg0 on $TARGET_HOST.${NC}"
        dump_wg_quick_journal
        exit 1
    fi
    echo -e "      ${GREEN}-> Reloaded wg-quick@wg0 on $TARGET_HOST.${NC}"
# enable --now is only for the very first setup
else
    if ! ssh "$TARGET_HOST" "sudo systemctl enable --now wg-quick@wg0"; then
        echo -e "      ${RED}-> Error: failed to enable/start wg-quick@wg0 on $TARGET_HOST.${NC}"
        dump_wg_quick_journal
        exit 1
    fi
    echo -e "      ${GREEN}-> Enabled and started wg-quick@wg0 on $TARGET_HOST.${NC}"
fi

# Verify the handshake on the target host
ssh "$TARGET_HOST" "sudo wg show wg0"
