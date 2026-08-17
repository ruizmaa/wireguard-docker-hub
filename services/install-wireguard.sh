#!/bin/bash
# Installs the WireGuard client tools needed for this home server to join the VPS tunnel as a peer.
# Run manually once, before following the "Connect to the VPS tunnel" step in SERVICES.md.
set -e
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

NO_INTERACTIVE_APT=(DEBIAN_FRONTEND=noninteractive apt-get)

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"

echo -e "    ${YELLOW}[1/2]${NC} Installing wireguard and resolvconf..."
sudo "${NO_INTERACTIVE_APT[@]}" update -qq > /dev/null
sudo "${NO_INTERACTIVE_APT[@]}" install -y -qq wireguard resolvconf > /dev/null

echo -e "    ${YELLOW}[2/2]${NC} Verifying installation..."
if command -v wg > /dev/null && command -v wg-quick > /dev/null; then
    echo -e "      ${GREEN}-> wg/wg-quick are available.${NC}"
else
    echo -e "      ${RED}-> Error: wireguard-tools verification failed.${NC}"
    exit 1
fi

if dpkg -s resolvconf > /dev/null 2>&1; then
    echo -e "      ${GREEN}-> resolvconf is installed.${NC}"
else
    echo -e "      ${RED}-> Error: resolvconf verification failed.${NC}"
    exit 1
fi
