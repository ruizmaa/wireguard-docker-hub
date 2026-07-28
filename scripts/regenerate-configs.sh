#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$SCRIPT_DIR/.."
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/lib/colors.sh"
CONFIG_DIR="$PROJECT_ROOT/config"
WG_CONF="$CONFIG_DIR/wg_confs/wg0.conf"

echo -e "${YELLOW}⚠️  WARNING:${NC} This will ${RED}DELETE${NC} all WireGuard configs and keys:"
echo -e "    ${YELLOW}$CONFIG_DIR${NC}"
echo -e "    and regenerate them based on your ${YELLOW}docker-compose.yml${NC}"
echo ""
read -r -p "$(echo -e "${YELLOW}Type ${RED}YES${YELLOW} to continue:${NC} ")" CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo -e "${RED}Aborted.${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}>>> STEP 1: Stopping WireGuard container...${NC}"
docker compose -f "$PROJECT_ROOT/docker-compose.yml" down > /dev/null

echo -e "${YELLOW}>>> STEP 2: Removing old configs...${NC}"
rm -rf "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR"

echo -e "${YELLOW}>>> STEP 3: Starting WireGuard (regenerate configs)...${NC}"
docker compose -f "$PROJECT_ROOT/docker-compose.yml" up -d > /dev/null

echo -e "${YELLOW}>>> STEP 4: Waiting for wg0.conf to be generated...${NC}"
TIMEOUT=0
echo -n "    Waiting"
while [ ! -f "$WG_CONF" ]; do
    sleep 1
    echo -n "."
    TIMEOUT=$((TIMEOUT+1))
    if [ $TIMEOUT -gt 30 ]; then
        echo ""
        echo -e "    ${RED}ERROR:${NC} wg0.conf was not generated within 30 seconds."
        exit 1
    fi
done

echo ""
echo -e "${GREEN}WireGuard configuration regenerated successfully!${NC}"
echo ""
