#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

NO_INTERACTIVE_APT="DEBIAN_FRONTEND=noninteractive apt-get"

# Detect real user (if not already defined)
if [ -z "$REAL_USER" ]; then
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        REAL_USER="$SUDO_USER"
    else
        REAL_USER="$USER"
    fi
fi
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export REAL_USER REAL_HOME

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$SCRIPT_DIR/.."
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"

# Basic system update and essential package installation
echo -e "    ${YELLOW}[1/6]${NC} Updating system and installing essential packages..."
sudo $NO_INTERACTIVE_APT update -qq > /dev/null
sudo $NO_INTERACTIVE_APT install -y -qq apt-utils 2>/dev/null || true
sudo $NO_INTERACTIVE_APT upgrade -y -qq > /dev/null
sudo $NO_INTERACTIVE_APT install -y -qq nano ca-certificates curl gnupg iputils-ping jq > /dev/null

# Basic configuration
echo -e "    ${YELLOW}[2/6]${NC} Configuring terminal..."
if [ -n "$REAL_HOME" ]; then
    BASHRC="$REAL_HOME/.bashrc"
    if ! grep -q "xterm-256color" "$BASHRC" 2>/dev/null; then
        echo 'export TERM=xterm-256color' | sudo tee -a "$BASHRC" > /dev/null
        sudo chown "$REAL_USER:$REAL_USER" "$BASHRC"
    fi
fi

# Install Docker
echo -e "    ${YELLOW}[3/6]${NC} Setting up Docker repository..."
. /etc/os-release
echo "      -> Detected Distro: $ID"
echo "      -> Detected Codename: $VERSION_CODENAME"

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/$ID/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: $VERSION_CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

echo -e "    ${YELLOW}[4/6]${NC} Installing Docker Engine..."
sudo $NO_INTERACTIVE_APT update -y -qq > /dev/null
sudo $NO_INTERACTIVE_APT install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null

echo -e "    ${YELLOW}[5/6]${NC} Configuring permissions..."
sudo usermod -aG docker "$REAL_USER"

echo -e "    ${YELLOW}[6/6]${NC} Verifying installation..."
if sudo -u "$REAL_USER" sg docker -c "docker run --rm hello-world" > /dev/null 2>&1; then
    echo -e "      ${GREEN}-> Docker is running correctly.${NC}"
else
    echo -e "      ${RED}-> Error: Docker verification failed.${NC}"
    exit 1
fi
