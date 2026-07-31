#!/bin/bash
# Reports current status of the firewall rules applied by fix-home-net.sh.
# Run manually to verify, or automatically as the last step of fix-home-net.sh.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/lib/colors.sh"
ENV_FILE="$SCRIPT_DIR/../services/.env"
WG_IFACE="wg0"

# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"

print_status() {
    # $1 = Message, $2 = Status (0=OK, 1=ERROR)
    if [ "$2" -eq 0 ]; then
        printf "    %-40s ${GREEN}[ OK  ]${NC}\n" "$1"
    else
        printf "    %-40s ${RED}[ERROR]${NC}\n" "$1"
    fi
}

SSH_PORT=$(sudo sshd -T 2>/dev/null | awk '/^port / && !p {print $2; p=1}')
SSH_PORT=${SSH_PORT:-22}

# Baseline INPUT accepts
if sudo iptables -C INPUT -i lo -j ACCEPT 2>/dev/null; then s1=0; else s1=1; fi
print_status "Firewall Loopback Accept" "$s1"

if sudo iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then s2=0; else s2=1; fi
print_status "Firewall Established/Related Accept" "$s2"

if sudo iptables -C INPUT -p icmp -j ACCEPT 2>/dev/null; then s3=0; else s3=1; fi
print_status "Firewall ICMP Accept" "$s3"

if sudo iptables -C INPUT -i "$WG_IFACE" -j ACCEPT 2>/dev/null; then s4=0; else s4=1; fi
print_status "Firewall WireGuard Accept" "$s4"

# HOST_GUARD: SSH gated through the trusted-devices allowlist
if sudo iptables -C HOST_GUARD -p tcp --dport "$SSH_PORT" -j TRUSTED_LAN 2>/dev/null; then s5=0; else s5=1; fi
print_status "Firewall HOST_GUARD SSH Rule" "$s5"

if sudo iptables -C INPUT -j HOST_GUARD 2>/dev/null; then s6=0; else s6=1; fi
print_status "Firewall INPUT->HOST_GUARD Jump" "$s6"

# DOCKER_GUARD: published container ports gated the same way
if sudo iptables -C DOCKER_GUARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then s7=0; else s7=1; fi
print_status "Firewall DOCKER_GUARD Accept Rule" "$s7"

if sudo iptables -C DOCKER_GUARD -i "$WG_IFACE" -m conntrack --ctstate DNAT -j ACCEPT 2>/dev/null; then s8=0; else s8=1; fi
print_status "Firewall DOCKER_GUARD WireGuard Rule" "$s8"

if sudo iptables -C DOCKER_GUARD -m conntrack --ctstate DNAT -j TRUSTED_LAN 2>/dev/null; then s9=0; else s9=1; fi
print_status "Firewall DOCKER_GUARD Allowlist Rule" "$s9"

if sudo iptables -C DOCKER_GUARD -m conntrack --ctstate DNAT -j DROP 2>/dev/null; then s10=0; else s10=1; fi
print_status "Firewall DOCKER_GUARD Deny Rule" "$s10"

if sudo iptables -C DOCKER-USER -j DOCKER_GUARD 2>/dev/null; then s11=0; else s11=1; fi
print_status "Firewall DOCKER-USER Jump" "$s11"

# Default-deny
if sudo iptables -S INPUT 2>/dev/null | head -n1 | grep -qE '^-P INPUT DROP$'; then s12=0; else s12=1; fi
print_status "Firewall INPUT Default-Deny" "$s12"

if sudo iptables -S FORWARD 2>/dev/null | head -n1 | grep -qE '^-P FORWARD DROP$'; then s13=0; else s13=1; fi
print_status "Firewall FORWARD Default-Deny" "$s13"

if sudo ip6tables -S INPUT 2>/dev/null | head -n1 | grep -qE '^-P INPUT DROP$'; then s14=0; else s14=1; fi
print_status "Firewall IPv6 INPUT Default-Deny" "$s14"

if sudo ip6tables -S FORWARD 2>/dev/null | head -n1 | grep -qE '^-P FORWARD DROP$'; then s15=0; else s15=1; fi
print_status "Firewall IPv6 FORWARD Default-Deny" "$s15"

# Per-device allowlist entries, read the same way fix-home-net.sh reads them
if [ -f "$ENV_FILE" ]; then
    TRUSTED_LAN_DEVICES=$(read_env TRUSTED_LAN_DEVICES "")
    if [ -n "$TRUSTED_LAN_DEVICES" ]; then
        IFS=',' read -ra DEVICE_LIST <<< "$TRUSTED_LAN_DEVICES"
        for device in "${DEVICE_LIST[@]}"; do
            ip="${device%%@*}"
            mac="${device#*@}"
            if sudo iptables -C TRUSTED_LAN -s "$ip" -m mac --mac-source "$mac" -j ACCEPT 2>/dev/null; then sd=0; else sd=1; fi
            print_status "Firewall TRUSTED_LAN Rule ($ip)" "$sd"
        done
    fi
fi
