#!/bin/bash
# Installs Docker Engine and base system dependencies.
# Invoked by easy-install.sh; can also be run manually/standalone.
set -e
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

NO_INTERACTIVE_APT=(DEBIAN_FRONTEND=noninteractive apt-get)

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

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/lib/colors.sh"

# Basic system update and essential package installation
echo -e "    ${YELLOW}[1/9]${NC} Updating system and installing essential packages..."
sudo "${NO_INTERACTIVE_APT[@]}" update -qq > /dev/null
sudo "${NO_INTERACTIVE_APT[@]}" install -y -qq apt-utils 2>/dev/null || true
sudo "${NO_INTERACTIVE_APT[@]}" upgrade -y -qq > /dev/null
sudo "${NO_INTERACTIVE_APT[@]}" install -y -qq nano ca-certificates curl gnupg iputils-ping jq fail2ban unattended-upgrades openssh-server > /dev/null

# Basic configuration
echo -e "    ${YELLOW}[2/9]${NC} Configuring terminal..."
if [ -n "$REAL_HOME" ]; then
    BASHRC="$REAL_HOME/.bashrc"
    if ! grep -q "xterm-256color" "$BASHRC" 2>/dev/null; then
        echo 'export TERM=xterm-256color' | sudo tee -a "$BASHRC" > /dev/null
        sudo chown "$REAL_USER:$REAL_USER" "$BASHRC"
    fi
fi

# Install Docker
echo -e "    ${YELLOW}[3/9]${NC} Setting up Docker repository..."
# shellcheck disable=SC1091 # runtime system file, not part of this repo
. /etc/os-release
echo "      -> Detected Distro: $ID"
echo "      -> Detected Codename: $VERSION_CODENAME"

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: $VERSION_CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

echo -e "    ${YELLOW}[4/9]${NC} Installing Docker Engine..."
sudo "${NO_INTERACTIVE_APT[@]}" update -y -qq > /dev/null
sudo "${NO_INTERACTIVE_APT[@]}" install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null

echo -e "    ${YELLOW}[5/9]${NC} Configuring permissions..."
sudo usermod -aG docker "$REAL_USER"

echo -e "    ${YELLOW}[6/9]${NC} Configuring and enabling fail2ban (SSH brute-force protection)..."
sudo mkdir -p /etc/fail2ban/jail.d
sudo tee /etc/fail2ban/jail.d/sshd.local > /dev/null <<EOF
[sshd]
enabled = true
port = ssh
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5
EOF
sudo systemctl enable fail2ban > /dev/null
sudo systemctl restart fail2ban > /dev/null

echo -e "    ${YELLOW}[7/9]${NC} Hardening SSH (disabling root login)..."
if [ "$REAL_USER" = "root" ]; then
    echo -e "      ${YELLOW}-> Skipped: no non-root user detected, disabling root login would lock this account out.${NC}"
else
    sudo mkdir -p /etc/ssh/sshd_config.d
    sudo tee /etc/ssh/sshd_config.d/99-harden.conf > /dev/null <<EOF
PermitRootLogin no
PasswordAuthentication no
EOF
    sudo mkdir -p /run/sshd
    sudo sshd -t
    sudo systemctl reload-or-restart ssh
fi

echo -e "    ${YELLOW}[8/9]${NC} Configuring and enabling unattended-upgrades (automatic security patches)..."
sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
sudo systemctl enable --now unattended-upgrades > /dev/null

echo -e "    ${YELLOW}[9/9]${NC} Verifying installation..."
if sudo -u "$REAL_USER" sg docker -c "docker run --rm hello-world" > /dev/null 2>&1; then
    echo -e "      ${GREEN}-> Docker is running correctly.${NC}"
else
    echo -e "      ${RED}-> Error: Docker verification failed.${NC}"
    exit 1
fi

if sudo systemctl is-active --quiet fail2ban && sudo fail2ban-client status sshd > /dev/null 2>&1; then
    echo -e "      ${GREEN}-> fail2ban is running and the sshd jail is loaded correctly.${NC}"
else
    echo -e "      ${RED}-> Error: fail2ban verification failed (daemon or sshd jail not active).${NC}"
    exit 1
fi

if [ "$REAL_USER" = "root" ]; then
    echo -e "      ${YELLOW}-> Skipped root-login/password-auth check (no non-root user detected).${NC}"
elif sudo sshd -T 2>/dev/null | grep -q '^permitrootlogin no$' && sudo sshd -T 2>/dev/null | grep -q '^passwordauthentication no$'; then
    echo -e "      ${GREEN}-> Root SSH login and SSH password authentication are disabled.${NC}"
else
    echo -e "      ${RED}-> Error: PermitRootLogin/PasswordAuthentication verification failed.${NC}"
    exit 1
fi

if sudo systemctl is-active --quiet unattended-upgrades; then
    echo -e "      ${GREEN}-> unattended-upgrades is running correctly.${NC}"
else
    echo -e "      ${RED}-> Error: unattended-upgrades verification failed.${NC}"
    exit 1
fi
