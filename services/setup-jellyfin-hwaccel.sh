#!/bin/bash
# Installs the Intel VAAPI drivers Jellyfin needs for QuickSync hardware transcoding through
# the /dev/dri device already passed in docker-compose.yml. Run once on the home server before
# the first `docker compose up`, only if it has an Intel iGPU (directly, or passed through to a
# VM, see SERVICES.md's Jellyfin section, "Running the home server as a Proxmox VM?" for VM setups).
# Usage: ./services/setup-jellyfin-hwaccel.sh
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"

if [ ! -e /dev/dri/renderD128 ]; then
    echo -e "${RED}Error: /dev/dri/renderD128 not found. No Intel iGPU visible on this host.${NC}"
    echo "If this is a VM, pass the iGPU through first (see SERVICES.md's Jellyfin section, 'Running the home server as a Proxmox VM?')."
    exit 1
fi

# shellcheck disable=SC1091 # runtime system file, not part of this repo
. /etc/os-release

if [ "$ID" != "debian" ]; then
    echo -e "${RED}Error: unsupported distro '$ID'. This script only supports Debian.${NC}"
    exit 1
fi

# intel-media-va-driver-non-free needs the 'non-free' component and firmware-misc-nonfree
# needs 'non-free-firmware'; neither is guaranteed enabled on the host. Add both as our own
# sources.list.d entry instead of patching the host's existing file, whose location and
# format (classic sources.list vs deb822 .sources) vary by release. Signed-By must match the
# host's own debian.sources verbatim (not just resolve to the same file): apt treats a second
# stanza for the same URI+Suite with a differently-spelled Signed-By (e.g. the .gpg vs .pgp
# symlink pair) as a conflict, not a duplicate, and refuses to read the sources at all.
SIGNED_BY="$(awk -F': *' '/^Signed-By:/ {print $2; exit}' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true)"
SIGNED_BY="${SIGNED_BY:-/usr/share/keyrings/debian-archive-keyring.gpg}"
echo "Enabling the 'non-free'/'non-free-firmware' apt components..."
sudo tee /etc/apt/sources.list.d/non-free.sources > /dev/null <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: $VERSION_CODENAME
Components: non-free non-free-firmware
Signed-By: $SIGNED_BY
EOF

echo "Installing VAAPI drivers and firmware..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq > /dev/null
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq intel-media-va-driver-non-free firmware-misc-nonfree vainfo > /dev/null

echo "Verifying VAAPI..."
if [ ! -r /dev/dri/renderD128 ] || [ ! -w /dev/dri/renderD128 ]; then
    DEVICE_GROUP="$(stat -c '%G' /dev/dri/renderD128)"
    echo -e "${RED}Error: your user can't read/write /dev/dri/renderD128 (it belongs to the '${DEVICE_GROUP}' group).${NC}"
    echo "Add yourself to it and log back in (or reboot), then re-run this script:"
    echo "  sudo usermod -aG ${DEVICE_GROUP} \$USER"
    exit 1
fi

if vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep -q VAProfile; then
    echo -e "${GREEN}VAAPI is working.${NC} Enable it in Jellyfin: Dashboard > Playback > Transcoding > Hardware acceleration > Intel QuickSync (QSV)."
else
    echo -e "${YELLOW}vainfo didn't report any VAProfile.${NC} If you just installed the firmware for the first time, reboot and re-run this script."
    echo "Still failing after a reboot? Check 'sudo dmesg | grep -i -e i915 -e guc -e huc' for driver/firmware errors."
    exit 1
fi
