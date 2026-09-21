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

TRUENAS_IP=$(read_env TRUENAS_IP "")
TRUENAS_MEDIA_PATH=$(read_env TRUENAS_MEDIA_PATH "")
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
CURRENT_SOURCE="$(findmnt -no SOURCE --target "${LOCAL_MOUNT_MEDIA_PATH}" 2>/dev/null || true)"
if [ "${CURRENT_SOURCE}" = "${NFS_SOURCE}" ]; then
    echo -e "${YELLOW}${LOCAL_MOUNT_MEDIA_PATH} is already mounted from ${NFS_SOURCE}, skipping.${NC}"
else
    if [ -n "${CURRENT_SOURCE}" ]; then
        echo "Unmounting stale mount from ${CURRENT_SOURCE}..."
        sudo umount "${LOCAL_MOUNT_MEDIA_PATH}"
    fi
    if sudo mount -t nfs "${NFS_SOURCE}" "${LOCAL_MOUNT_MEDIA_PATH}"; then
        echo -e "${GREEN}Mount succeeded.${NC}"
    else
        echo -e "${RED}Error: failed to mount ${NFS_SOURCE} at ${LOCAL_MOUNT_MEDIA_PATH}.${NC}"
        exit 1
    fi
fi

echo "Contents of ${LOCAL_MOUNT_MEDIA_PATH}:"
ls -la "${LOCAL_MOUNT_MEDIA_PATH}"

echo "Persisting the mount in /etc/fstab..."
if awk -v src="${NFS_SOURCE}" -v path="${LOCAL_MOUNT_MEDIA_PATH}" '$1 !~ /^#/ && $1 == src && $2 == path { found=1 } END { exit !found }' /etc/fstab; then
    echo -e "${YELLOW}An entry for ${NFS_SOURCE} -> ${LOCAL_MOUNT_MEDIA_PATH} already exists in /etc/fstab, skipping.${NC}"
else
    # Drop any stale entry for this mount point (e.g. from an older TRUENAS_MEDIA_PATH) before adding the current one
    TMP_FSTAB="$(mktemp)"
    awk -v path="${LOCAL_MOUNT_MEDIA_PATH}" '$1 ~ /^#/ || $2 != path' /etc/fstab > "${TMP_FSTAB}"
    sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    sudo install -m 644 "${TMP_FSTAB}" /etc/fstab
    rm -f "${TMP_FSTAB}"
    echo "${FSTAB_ENTRY}" | sudo tee -a /etc/fstab > /dev/null
    echo -e "${GREEN}Entry added to /etc/fstab.${NC}"
fi

echo -e "${GREEN}NFS setup complete.${NC}"
