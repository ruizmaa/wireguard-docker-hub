#!/bin/bash
# Reports current status of kernel forwarding, MTU and firewall rules.
# Run manually to verify, or automatically as the last step of fix-vps-net.sh.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/lib/colors.sh"
WG_CONF="$SCRIPT_DIR/../config/wg_confs/wg0.conf"
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

print_status() {
    # $1 = Message, $2 = Status (0=OK, 1=ERROR)
    if [ "$2" -eq 0 ]; then
        printf "    %-40s ${GREEN}[ OK  ]${NC}\n" "$1"
    else
        printf "    %-40s ${RED}[ERROR]${NC}\n" "$1"
    fi
}

# Kernel
sysctl_fwd=$(sysctl -n net.ipv4.ip_forward)
[ "$sysctl_fwd" -eq 1 ] && s1=0 || s1=1
print_status "Kernel IP Forwarding" "$s1"

sysctl_mark=$(sysctl -n net.ipv4.conf.all.src_valid_mark)
[ "$sysctl_mark" -eq 1 ] && s2=0 || s2=1
print_status "Kernel Valid Mark" "$s2"

# MTU
if [ -f "$WG_CONF" ] && grep -qE "MTU\s*=\s*1420" "$WG_CONF"; then s3=0; else s3=1; fi
print_status "MTU Configuration (1420)" "$s3"

# Firewall
if sudo iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then s4=0; else s4=1; fi
print_status "Firewall NAT Rule" "$s4"

if sudo iptables -C INPUT -i wg0 -j ACCEPT 2>/dev/null; then s5=0; else s5=1; fi
print_status "Firewall Input Rule" "$s5"

if sudo iptables -C INPUT -p udp --dport 51820 -j ACCEPT 2>/dev/null; then s6=0; else s6=1; fi
print_status "Firewall UDP 51820 Open" "$s6"

SSH_PORT=$(sudo sshd -T 2>/dev/null | awk '/^port / && !p {print $2; p=1}')
SSH_PORT=${SSH_PORT:-22}
if sudo iptables -C INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null; then s7=0; else s7=1; fi
print_status "Firewall SSH Rule" "$s7"

if sudo iptables -S INPUT 2>/dev/null | head -n1 | grep -qE '^-P INPUT DROP$'; then s8=0; else s8=1; fi
print_status "Firewall INPUT Default-Deny" "$s8"

if sudo iptables -S FORWARD 2>/dev/null | head -n1 | grep -qE '^-P FORWARD DROP$'; then s9=0; else s9=1; fi
print_status "Firewall FORWARD Default-Deny" "$s9"