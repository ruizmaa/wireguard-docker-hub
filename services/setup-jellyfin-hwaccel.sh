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

# intel-media-va-driver-non-free lives in the 'non-free' component, separate from the
# 'non-free-firmware' component a default Debian install already has enabled.
if ! grep -qE '^deb .* non-free( |$)' /etc/apt/sources.list; then
    echo "Enabling the 'non-free' apt component..."
    sudo sed -i -E 's/^(deb(-src)? .*)non-free-firmware/\1non-free non-free-firmware/' /etc/apt/sources.list
fi

echo "Installing VAAPI drivers and firmware..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq > /dev/null
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq intel-media-va-driver-non-free firmware-misc-nonfree vainfo > /dev/null

echo "Verifying VAAPI..."
if vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep -q VAProfile; then
    echo -e "${GREEN}VAAPI is working.${NC} Enable it in Jellyfin: Dashboard > Playback > Transcoding > Hardware acceleration > Intel QuickSync (QSV)."
else
    echo -e "${YELLOW}vainfo didn't report any VAProfile.${NC} If you just installed the firmware for the first time, reboot and re-run this script."
    echo "Still failing after a reboot? Check 'sudo dmesg | grep -i -e i915 -e guc -e huc' for driver/firmware errors."
    exit 1
fi
