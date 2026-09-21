#!/bin/bash
# Installs the Intel VAAPI drivers Jellyfin needs for QuickSync hardware transcoding.
# Run once on the home server before the first `docker compose up` if it has an Intel iGPU.
# For Proxmox VMs, pass the iGPU through first (see SERVICES.md's Jellyfin section).
# Usage: ./services/setup-jellyfin-hwaccel.sh
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"

NO_INTERACTIVE_APT=(DEBIAN_FRONTEND=noninteractive apt-get)

echo -e "    ${YELLOW}[1/5] Checking Intel iGPU...${NC}"
# Require an Intel render device to be visible before installing the VAAPI drivers
if [ ! -e /dev/dri/renderD128 ]; then
    echo -e "    ${RED}-> ERROR: /dev/dri/renderD128 not found. No Intel iGPU visible on this host.${NC}"
    echo "      If this is a VM, pass the iGPU through first (see SERVICES.md's Jellyfin section, 'Running the home server as a Proxmox VM?')."
    exit 1
fi
echo "      -> Intel render device found: /dev/dri/renderD128"

# Read the host distribution information provided by the system.
# shellcheck disable=SC1091 # runtime system file, not part of this repo
. /etc/os-release

# This script relies on Debian's apt repositories and package names
if [ "$ID" != "debian" ]; then
    echo -e "    ${RED}-> ERROR: unsupported distro '$ID'. This script only supports Debian.${NC}"
    exit 1
fi
echo "      -> Detected Distro: $ID"
echo "      -> Detected Codename: $VERSION_CODENAME"

echo -e "    ${YELLOW}[2/5] Enabling non-free apt components...${NC}"

# The Intel VAAPI driver needs 'non-free' and the firmware package needs
# 'non-free-firmware'. Add them in a separate deb822 source instead of modifying
# the host's existing source configuration, whose format varies by Debian release.

# Signed-By must match the host's debian.sources verbatim (not just resolve to the
# same file): apt treats a second stanza for the same URI+Suite with a differently
# spelled Signed-By (e.g. the .gpg vs .pgp symlink pair) as a conflict.
SIGNED_BY="$(awk -F': *' '/^Signed-By:/ {print $2; exit}' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true)"
SIGNED_BY="${SIGNED_BY:-/usr/share/keyrings/debian-archive-keyring.gpg}"

sudo tee /etc/apt/sources.list.d/non-free.sources > /dev/null <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: $VERSION_CODENAME
Components: non-free non-free-firmware
Signed-By: $SIGNED_BY
EOF

echo "      -> non-free and non-free-firmware enabled."

echo -e "    ${YELLOW}[3/5] Installing VAAPI drivers and firmware...${NC}"
sudo "${NO_INTERACTIVE_APT[@]}" update -qq > /dev/null
sudo "${NO_INTERACTIVE_APT[@]}" install -y -qq \
    intel-media-va-driver-non-free \
    firmware-misc-nonfree \
    vainfo > /dev/null

echo -e "    ${YELLOW}[4/5] Verifying render device permissions...${NC}"
# The current user must be able to access the render device so VAAPI can be verified,
# and Jellyfin needs the device's group inside the container for QuickSync access
DEVICE_GID="$(stat -c '%g' /dev/dri/renderD128)"
if [ ! -r /dev/dri/renderD128 ] || [ ! -w /dev/dri/renderD128 ]; then
    DEVICE_GROUP="$(stat -c '%G' /dev/dri/renderD128)"
    echo -e "    ${RED}-> ERROR: your user can't read/write /dev/dri/renderD128 (it belongs to the '${DEVICE_GROUP}' group).${NC}"
    echo "      Add yourself to it and log back in (or reboot), then re-run this script:"
    echo "        sudo usermod -aG ${DEVICE_GROUP} \$USER"
    exit 1
fi
echo "      -> /dev/dri/renderD128 is readable and writable."

echo -e "    ${YELLOW}[5/5] Verifying VAAPI...${NC}"
# Require vainfo to report at least one VAAPI profile before considering the setup successful
if vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep -q VAProfile; then
    echo -e "      ${GREEN}-> VAAPI is working.${NC}"
echo "      -> Add this to services/.env and re-run 'docker compose up -d':"
echo "         JELLYFIN_RENDER_GID=${DEVICE_GID}"
    echo "      -> Enable Intel QuickSync (QSV) in Jellyfin:"
    echo "         Dashboard > Playback > Transcoding > Hardware acceleration"
else
    echo -e "      ${YELLOW}-> WARNING: vainfo didn't report any VAProfile.${NC}"
    echo "      If you just installed the firmware for the first time, reboot and re-run this script."
    echo "      Still failing after a reboot? Check:"
    echo "        sudo dmesg | grep -i -e i915 -e guc -e huc"
    exit 1
fi

echo -e "${GREEN}Jellyfin hardware acceleration setup complete.${NC}"
