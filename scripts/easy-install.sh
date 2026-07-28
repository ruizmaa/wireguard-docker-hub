#!/bin/bash
# Full automated installer: Docker setup, .env config, container start and network fixes.
# Run manually once on a fresh VPS, e.g. sudo ./scripts/easy-install.sh.
set -e

# Detect real user (if not already defined)
if [ -z "$REAL_USER" ]; then
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        REAL_USER="$SUDO_USER"
    else
        REAL_USER="$USER"
    fi
fi
export REAL_USER

REAL_UID=$(id -u "$REAL_USER")
REAL_GID=$(id -g "$REAL_USER")

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/lib/colors.sh"

echo -e "${CYAN}==============================================${NC}"
echo -e "${CYAN}   WIREGUARD HUB - AUTOMATED INSTALLER        ${NC}"
echo -e "${CYAN}==============================================${NC}"

PROJECT_ROOT="$SCRIPT_DIR/.."
ENV_FILE="$PROJECT_ROOT/.env"
WG_CONFIG="$PROJECT_ROOT/config/wg_confs/wg0.conf"
TIMEOUT=0

# Run base Docker installation
echo ""
echo -e "\n${YELLOW}>>> STEP 1: Installing Docker & System Deps...${NC}"
sudo --preserve-env=REAL_USER bash "$SCRIPT_DIR/basic-install.sh"

# Detect and inject public IP
echo ""
echo -e "\n${YELLOW}>>> STEP 2: Configuring Public IP & Permissions...${NC}"
PUBLIC_IP=$(curl -fsSL https://ifconfig.me)
if ! [[ "$PUBLIC_IP" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
    || [ "${BASH_REMATCH[1]}" -gt 255 ] || [ "${BASH_REMATCH[2]}" -gt 255 ] \
    || [ "${BASH_REMATCH[3]}" -gt 255 ] || [ "${BASH_REMATCH[4]}" -gt 255 ]; then
    echo -e "    ${RED}Error: could not determine a valid public IPv4 address (got: '$PUBLIC_IP')${NC}"
    exit 1
fi
echo "    Detected IP: $PUBLIC_IP"
echo "    Using REAL_USER=$REAL_USER (UID=$REAL_UID, GID=$REAL_GID)"

touch "$ENV_FILE"
sed -i "/^SERVERURL=/d;/^PUID=/d;/^PGID=/d" "$ENV_FILE"
{
    echo "SERVERURL=$PUBLIC_IP"
    echo "PUID=$REAL_UID"
    echo "PGID=$REAL_GID"
} >> "$ENV_FILE"

echo -e "    ${GREEN}IP and PUID/PGID written to .env${NC}"

# Start Docker (to generate configs)
echo ""
echo -e "\n${YELLOW}>>> STEP 3: Starting WireGuard (Generating Configs)...${NC}"
cd "$PROJECT_ROOT"
sudo docker compose up -d > /dev/null

echo -n "    Waiting for config generation"
while [ ! -f "$WG_CONFIG" ]; do
    sleep 1
    echo -n "."
    TIMEOUT=$((TIMEOUT+1))
    if [ $TIMEOUT -gt 30 ]; then
        echo ""
        echo -e "    ${RED}Error: Timed out waiting for $WG_CONFIG${NC}"
        echo "    Check path (is it wg0.conf or wg_confs/wg0.conf?)"
        exit 1
    fi
done
echo ""
echo -e "    ${GREEN}File generated successfully!${NC}"

# Apply network fixes (MTU & iptables)
echo ""
echo -e "\n${YELLOW}>>> STEP 4: Applying Network Fixes (MTU & Firewall)...${NC}"
sudo --preserve-env=REAL_USER bash "$SCRIPT_DIR/fix-vps-net.sh"

# Finalize and fix permissions
echo ""
echo -e "\n${YELLOW}>>> STEP 5: Finalizing...${NC}"
cd "$PROJECT_ROOT"
sudo docker compose restart > /dev/null

# Return ownership of files to the real user (not root)
if [ -n "$REAL_USER" ]; then
    echo "    Fixing file permissions for user: $REAL_USER"
    sudo chown -R "$REAL_USER:$REAL_USER" "$PROJECT_ROOT/config"
    sudo chown "$REAL_USER:$REAL_USER" "$ENV_FILE"
fi

echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}           INSTALLATION COMPLETE!             ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo ""
echo -e "${CYAN}IMPORTANT:${NC}"
echo -e "To use Docker without 'sudo' and fix terminal colors,"
echo -e "please log out and log back in. Run this:"
echo ""
echo -e "    ${YELLOW}exit${NC}"
echo ""
