#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

NO_INTERACTIVE_APT=(DEBIAN_FRONTEND=noninteractive apt-get)

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/lib/colors.sh"
WG_CONF="$SCRIPT_DIR/../config/wg_confs/wg0.conf"
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

echo -e "    ${YELLOW}[1/7] Detecting interface...${NC}"
echo "      -> Detected Interface: $IFACE"
echo "      -> Config Path: $WG_CONF"

# Install required packages
echo -e "    ${YELLOW}[2/7] Installing required packages for network fixes...${NC}"
sudo "${NO_INTERACTIVE_APT[@]}" update -y -qq > /dev/null
sudo "${NO_INTERACTIVE_APT[@]}" upgrade -y -qq > /dev/null

echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
sudo "${NO_INTERACTIVE_APT[@]}" install -y -qq iptables-persistent netfilter-persistent > /dev/null

# Kernel settings
echo -e "    ${YELLOW}[3/7] Configuring Kernel Forwarding...${NC}"
cat <<EOF | sudo tee /etc/sysctl.d/99-wireguard-optimize.conf > /dev/null
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
EOF
sudo sysctl -p /etc/sysctl.d/99-wireguard-optimize.conf > /dev/null

# Fix MTU
echo -e "    ${YELLOW}[4/7] Checking MTU configuration...${NC}"
if [ -f "$WG_CONF" ]; then
    if grep -qE "MTU\s*=" "$WG_CONF"; then
        echo "      -> MTU was already configured."
    else
        echo "      -> Injecting MTU = 1420 into $WG_CONF..."
        sudo sed -i '/\[Interface\]/a MTU = 1420' "$WG_CONF"
    fi
else
    echo -e "      ${RED}-> ERROR: $WG_CONF not found. Start the container first.${NC}"
    echo "      -> Please start the Docker container ONCE to generate the config, run this script to apply the MTU setting."
    echo "      -> Also check path (is it wg0.conf or wg_confs/wg0.conf?)"
fi

# NAT (Masquerade) rules
echo -e "    ${YELLOW}[5/7] Applying Firewall rules...${NC}"
sudo iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2> /dev/null || true

add_rule() {
    if ! sudo iptables -C "$@" 2>/dev/null; then
        sudo iptables -I "$@"
    fi
}

add_rule INPUT -p udp --dport 51820 -j ACCEPT
add_rule INPUT -i wg0 -j ACCEPT
add_rule FORWARD -i wg0 -j ACCEPT
add_rule FORWARD -o wg0 -j ACCEPT

if ! sudo iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    echo "      -> Added NAT Masquerade rule."
fi

# Rules persistently
echo -e "    ${YELLOW}[6/7] Saving firewall rules...${NC}"
sudo netfilter-persistent save > /dev/null

# Final configuration check
echo -e "    ${YELLOW}[7/7] Final network configuration check:${NC}"
bash "$SCRIPT_DIR/check-network-config.sh"
