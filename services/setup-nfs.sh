#!/bin/bash
# Mounts the TrueNAS NFS share at LOCAL_MOUNT_MEDIA_PATH and persists it in /etc/fstab, so
# radarr/sonarr/qbittorrent/jellyfin all see the same media library. Run once on the home
# server before the first `docker compose up`.
# Usage: ./services/setup-nfs.sh
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"
# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/../scripts/lib/env.sh"

ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: $ENV_FILE not found. Copy .env.example to services/.env and set TRUENAS_IP/TRUENAS_MEDIA_PATH first.${NC}"
    exit 1
fi

TRUENAS_IP=$(read_env TRUENAS_IP)
TRUENAS_MEDIA_PATH=$(read_env TRUENAS_MEDIA_PATH)
LOCAL_MOUNT_MEDIA_PATH=$(read_env LOCAL_MOUNT_MEDIA_PATH "/mnt/nas_media")

if [ -z "$TRUENAS_IP" ] || [ -z "$TRUENAS_MEDIA_PATH" ]; then
    echo -e "${RED}Error: TRUENAS_IP or TRUENAS_MEDIA_PATH is empty in $ENV_FILE.${NC}"
    exit 1
fi

NFS_SOURCE="${TRUENAS_IP}:${TRUENAS_MEDIA_PATH}"
FSTAB_ENTRY="${NFS_SOURCE}  ${LOCAL_MOUNT_MEDIA_PATH}  nfs  defaults,_netdev,nofail,bg  0  0"

echo "Setting up NFS mount from ${NFS_SOURCE} to ${LOCAL_MOUNT_MEDIA_PATH}..."

echo "Installing nfs-common..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq > /dev/null
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-common > /dev/null

echo "Creating mount point ${LOCAL_MOUNT_MEDIA_PATH}..."
sudo mkdir -p "${LOCAL_MOUNT_MEDIA_PATH}"

echo "Testing the mount..."
if sudo mount -t nfs "${NFS_SOURCE}" "${LOCAL_MOUNT_MEDIA_PATH}"; then
    echo -e "${GREEN}Mount succeeded.${NC}"
else
    echo -e "${RED}Error: failed to mount ${NFS_SOURCE} at ${LOCAL_MOUNT_MEDIA_PATH}.${NC}"
    exit 1
fi

echo "Contents of ${LOCAL_MOUNT_MEDIA_PATH}:"
ls -la "${LOCAL_MOUNT_MEDIA_PATH}"

echo "Persisting the mount in /etc/fstab..."
if grep -qs "${LOCAL_MOUNT_MEDIA_PATH}" /etc/fstab; then
    echo -e "${YELLOW}An entry for ${LOCAL_MOUNT_MEDIA_PATH} already exists in /etc/fstab, skipping.${NC}"
else
    echo "${FSTAB_ENTRY}" | sudo tee -a /etc/fstab > /dev/null
    echo -e "${GREEN}Entry added to /etc/fstab.${NC}"
fi

echo -e "${GREEN}NFS setup complete.${NC}"
