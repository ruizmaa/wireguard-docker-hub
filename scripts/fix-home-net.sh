#!/bin/bash
# Restricts SSH/services to trusted LAN devices
# VPN is always allowed. Re-run after changing TRUSTED_LAN_DEVICES in services/.env.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

NO_INTERACTIVE_APT=(DEBIAN_FRONTEND=noninteractive apt-get)

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/lib/colors.sh"
ENV_FILE="$SCRIPT_DIR/../services/.env"
WG_IFACE="wg0"

# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"

echo -e "    ${YELLOW}[1/8] Reading configuration...${NC}"
if [ ! -f "$ENV_FILE" ]; then
    echo -e "    ${RED}-> ERROR: $ENV_FILE not found. Copy .env.example to services/.env and set TRUSTED_LAN_DEVICES first.${NC}"
    exit 1
fi

TRUSTED_LAN_DEVICES=$(read_env TRUSTED_LAN_DEVICES "")
if [ -z "$TRUSTED_LAN_DEVICES" ]; then
    echo -e "    ${RED}-> ERROR: TRUSTED_LAN_DEVICES is empty in $ENV_FILE.${NC}"
    echo "      Set it to a comma-separated list of your trusted devices' IP@MAC pairs first (no spaces), e.g.:"
    echo "      TRUSTED_LAN_DEVICES=192.168.1.10@aa:bb:cc:dd:ee:ff,192.168.1.11@11:22:33:44:55:66"
    exit 1
fi

SSH_PORT=$(sudo sshd -T 2>/dev/null | awk '/^port / && !p {print $2; p=1}')
SSH_PORT=${SSH_PORT:-22}

# Requires both IP and MAC per device
# An IP alone can be spoofed by anyone on the LAN
IFS=',' read -ra DEVICE_LIST <<< "$TRUSTED_LAN_DEVICES"
TRUSTED_IPS=()
TRUSTED_MACS=()
for device in "${DEVICE_LIST[@]}"; do
    # Each entry looks like IP@MAC , split it in two
    ip="${device%%@*}"
    mac="${device#*@}"
    if [[ "$device" != *"@"* ]]; then
        echo -e "    ${RED}-> ERROR: '$device' is missing the @MAC part (expected IP@MAC).${NC}"
        exit 1
    fi
    if ! [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
        || [ "${BASH_REMATCH[1]}" -gt 255 ] || [ "${BASH_REMATCH[2]}" -gt 255 ] \
        || [ "${BASH_REMATCH[3]}" -gt 255 ] || [ "${BASH_REMATCH[4]}" -gt 255 ]; then
        echo -e "    ${RED}-> ERROR: '$ip' is not a valid IPv4 address.${NC}"
        exit 1
    fi
    if ! [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        echo -e "    ${RED}-> ERROR: '$mac' is not a valid MAC address (expected aa:bb:cc:dd:ee:ff).${NC}"
        exit 1
    fi
    TRUSTED_IPS+=("$ip")
    TRUSTED_MACS+=("$mac")
done

# The SSH port must be a valid port number
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo -e "    ${RED}-> ERROR: SSH_PORT='$SSH_PORT' is not a valid port (1-65535).${NC}"
    exit 1
fi
echo "      -> Trusted devices: ${DEVICE_LIST[*]}"
echo "      -> SSH port: $SSH_PORT"

echo -e "    ${YELLOW}[2/8] Checking trusted devices answer on the LAN...${NC}"
# Never blocks the script, a device can be legitimately offline or block ICMP
# Collected into DEVICE_WARNINGS to repeat at the end, past all the noisy apt/iptables output
DEVICE_WARNINGS=()
for i in "${!TRUSTED_IPS[@]}"; do
    ip="${TRUSTED_IPS[$i]}"
    mac="${TRUSTED_MACS[$i]}"
    # Forces an ARP refresh so the neighbor table below isn't stale
    sudo ping -c 1 -W 1 "$ip" > /dev/null 2>&1 || true
    # Whatever MAC is actually answering at that IP right now, if any
    seen_mac=$(sudo ip neigh show "$ip" 2>/dev/null | awk '{for (j=1;j<=NF;j++) if ($j=="lladdr") print $(j+1)}' | head -n1) || true
    if [ -z "$seen_mac" ]; then
        msg="$ip didn't answer on the LAN (device off, wrong IP, or it blocks ICMP)."
        echo -e "      ${YELLOW}-> WARNING: $msg${NC}"
        DEVICE_WARNINGS+=("$msg")
    elif [ "${seen_mac,,}" != "${mac,,}" ]; then
        msg="$ip answered with MAC $seen_mac, not the configured $mac (typo, or a stale DHCP lease?)."
        echo -e "      ${YELLOW}-> WARNING: $msg${NC}"
        DEVICE_WARNINGS+=("$msg")
    else
        echo "      -> $ip@$mac confirmed on the LAN"
    fi
done

# Inserts at the top, skipping it if already there. Only safe for rules whose exact text never changes
add_rule() {
    if ! sudo iptables -C "$@" 2>/dev/null; then
        sudo iptables -I "$@"
    fi
}
# Empties the chain (creating it first if missing). It gets rebuilt from scratch every run
rebuild_chain() {
    sudo iptables -N "$1" 2>/dev/null || true
    sudo iptables -F "$1"
}

echo -e "    ${YELLOW}[3/8] Installing required packages...${NC}"
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
sudo "${NO_INTERACTIVE_APT[@]}" update -y -qq > /dev/null
sudo "${NO_INTERACTIVE_APT[@]}" install -y -qq iptables-persistent netfilter-persistent > /dev/null

echo -e "    ${YELLOW}[4/8] Rebuilding the trusted-devices allowlist...${NC}"
rebuild_chain TRUSTED_LAN
for i in "${!TRUSTED_IPS[@]}"; do
    sudo iptables -A TRUSTED_LAN -s "${TRUSTED_IPS[$i]}" -m mac --mac-source "${TRUSTED_MACS[$i]}" -j ACCEPT
done

echo -e "    ${YELLOW}[5/8] Applying firewall rules...${NC}"

# Never locks out this SSH session or the WireGuard tunnel
add_rule INPUT -i lo -j ACCEPT
add_rule INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
add_rule INPUT -p icmp -j ACCEPT
add_rule INPUT -i "$WG_IFACE" -j ACCEPT

# SSH is a host process, so INPUT filtering works here
rebuild_chain HOST_GUARD
sudo iptables -A HOST_GUARD -p tcp --dport "$SSH_PORT" -j TRUSTED_LAN
add_rule INPUT -j HOST_GUARD

# Docker DNATs published ports before INPUT is checked, so this guards DOCKER-USER instead
rebuild_chain DOCKER_GUARD
# Needed for reply traffic, or every connection breaks after the first packet
sudo iptables -A DOCKER_GUARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Trust the VPN tunnel too, but only to reach a published port
# Without ctstate DNAT this would accept any forwarded wg0 traffic, to any destination
sudo iptables -A DOCKER_GUARD -i "$WG_IFACE" -m conntrack --ctstate DNAT -j ACCEPT
# Matched by NAT state, not port, so any published port is covered automatically
sudo iptables -A DOCKER_GUARD -m conntrack --ctstate DNAT -j TRUSTED_LAN
sudo iptables -A DOCKER_GUARD -m conntrack --ctstate DNAT -j DROP
# Re-insert at the top instead of add_rule, since it only checks existence, not position
while sudo iptables -D DOCKER-USER -j DOCKER_GUARD 2>/dev/null; do :; done
sudo iptables -I DOCKER-USER -j DOCKER_GUARD

sudo iptables -P INPUT DROP
# Backstop for anything reaching FORWARD that DOCKER_GUARD didn't explicitly accept or drop
sudo iptables -P FORWARD DROP

echo -e "    ${YELLOW}[6/8] Blocking IPv6 (unused by this project)...${NC}"
# Same baseline accepts as IPv4: loopback, existing connections, and ICMPv6 (needed for neighbor discovery)
sudo ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null || sudo ip6tables -I INPUT -i lo -j ACCEPT
sudo ip6tables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
    || sudo ip6tables -I INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo ip6tables -C INPUT -p icmpv6 -j ACCEPT 2>/dev/null || sudo ip6tables -I INPUT -p icmpv6 -j ACCEPT
# No IPv6 allowlist at all. This project doesn't use it, so just block everything
sudo ip6tables -P INPUT DROP
sudo ip6tables -P FORWARD DROP

echo -e "    ${YELLOW}[7/8] Saving firewall rules...${NC}"
sudo netfilter-persistent save > /dev/null

echo -e "    ${YELLOW}[8/8] Final network configuration check:${NC}"
bash "$SCRIPT_DIR/check-network-config-home.sh"

echo -e "    ${GREEN}Done.${NC} SSH/AdGuard/Homepage/Jellyfin/Syncthing are now reachable only from: ${DEVICE_LIST[*]}"
echo "    VPN access via $WG_IFACE is unaffected. IPv6 is blocked entirely."

if [ "${#DEVICE_WARNINGS[@]}" -gt 0 ]; then
    echo ""
    echo -e "    ${YELLOW}Reminder: ${#DEVICE_WARNINGS[@]} trusted device(s) didn't check out earlier --${NC}"
    for msg in "${DEVICE_WARNINGS[@]}"; do
        echo -e "      ${YELLOW}-> $msg${NC}"
    done
fi
