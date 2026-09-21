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

NO_INTERACTIVE_APT=(DEBIAN_FRONTEND=noninteractive apt-get)

ENV_FILE="$SCRIPT_DIR/.env"

echo -e "    ${YELLOW}[1/5] Reading configuration...${NC}"
# Require the services environment file to be present
if [ ! -f "$ENV_FILE" ]; then
    echo -e "    ${RED}-> ERROR: $ENV_FILE not found. Copy .env.example to services/.env and set TRUENAS_IP/TRUENAS_MEDIA_PATH first.${NC}"
    exit 1
fi

TRUENAS_IP=$(read_env TRUENAS_IP "")
TRUENAS_MEDIA_PATH=$(read_env TRUENAS_MEDIA_PATH "")
LOCAL_MOUNT_MEDIA_PATH=$(read_env LOCAL_MOUNT_MEDIA_PATH "/mnt/nas_media")

# Ensure the TrueNAS address and remote media path are configured
if [ -z "$TRUENAS_IP" ] || [ -z "$TRUENAS_MEDIA_PATH" ]; then
    echo -e "    ${RED}-> ERROR: TRUENAS_IP or TRUENAS_MEDIA_PATH is empty in $ENV_FILE.${NC}"
    exit 1
fi

# Prevent a typo in LOCAL_MOUNT_MEDIA_PATH from allowing the stale-mount cleanup to unmount /
if [ "$LOCAL_MOUNT_MEDIA_PATH" = "/" ]; then
    echo -e "    ${RED}-> ERROR: LOCAL_MOUNT_MEDIA_PATH is '/' in $ENV_FILE. Refusing to use the root filesystem as the NFS mount point.${NC}"
    exit 1
fi

NFS_SOURCE="${TRUENAS_IP}:${TRUENAS_MEDIA_PATH}"
# Let systemd mount the share on first access, so Docker bind mounts wait for NFS
# instead of racing the mount and seeing an empty local directory
FSTAB_ENTRY="${NFS_SOURCE}  ${LOCAL_MOUNT_MEDIA_PATH}  nfs  defaults,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=30  0  0"

echo "      -> NFS source: $NFS_SOURCE"
echo "      -> Mount point: $LOCAL_MOUNT_MEDIA_PATH"

echo -e "    ${YELLOW}[2/5] Installing NFS client...${NC}"
sudo "${NO_INTERACTIVE_APT[@]}" update -qq > /dev/null
sudo "${NO_INTERACTIVE_APT[@]}" install -y -qq nfs-common > /dev/null

echo -e "    ${YELLOW}[3/5] Configuring NFS mount...${NC}"
sudo mkdir -p "$LOCAL_MOUNT_MEDIA_PATH"

# Read the current mount source only when the path is actually mounted. On a plain directory,
# findmnt --target would resolve to the nearest ancestor mount (e.g. the root filesystem).
CURRENT_SOURCE=""
if mountpoint -q "$LOCAL_MOUNT_MEDIA_PATH"; then
    CURRENT_SOURCE="$(findmnt -no SOURCE --target "$LOCAL_MOUNT_MEDIA_PATH")"
fi

# Keep the existing mount when it already points to the configured NFS share
if [ "$CURRENT_SOURCE" = "$NFS_SOURCE" ]; then
    echo -e "      ${YELLOW}-> $LOCAL_MOUNT_MEDIA_PATH is already mounted from $NFS_SOURCE.${NC}"
else
    # Remove any existing mount that points to a different source.
    if [ -n "$CURRENT_SOURCE" ]; then
        echo "      -> Unmounting stale mount from $CURRENT_SOURCE..."
        sudo umount -l "$LOCAL_MOUNT_MEDIA_PATH"
    fi

    echo "      -> Checking connectivity to $TRUENAS_IP:2049 (NFS)..."
    # Require the TrueNAS NFS port to be reachable before attempting the mount
    # $1 prevents command injection if TRUENAS_IP contains shell special characters
    if ! timeout 5 bash -c 'echo > "/dev/tcp/$1/2049"' _ "$TRUENAS_IP" 2>/dev/null; then
        echo -e "      ${RED}-> ERROR: cannot reach $TRUENAS_IP on port 2049 (NFS). Is TrueNAS up and TRUENAS_IP correct?${NC}"
        exit 1
    fi

    # Mount the configured TrueNAS share at the local media path
    if sudo mount -t nfs "$NFS_SOURCE" "$LOCAL_MOUNT_MEDIA_PATH"; then
        echo -e "      ${GREEN}-> NFS mount succeeded.${NC}"
    else
        echo -e "      ${RED}-> ERROR: failed to mount $NFS_SOURCE at $LOCAL_MOUNT_MEDIA_PATH.${NC}"
        exit 1
    fi
fi

echo -e "    ${YELLOW}[4/5] Verifying NFS mount...${NC}"
echo "      -> Contents of $LOCAL_MOUNT_MEDIA_PATH:"

# Show the mounted share contents as a basic access check
ls -la "$LOCAL_MOUNT_MEDIA_PATH" || echo -e "      ${YELLOW}-> WARNING: couldn't list $LOCAL_MOUNT_MEDIA_PATH (permission issue?). The mount itself succeeded.${NC}"

echo -e "    ${YELLOW}[5/5] Persisting mount in /etc/fstab...${NC}"

# Keep the existing entry when it already matches the configured NFS share
if awk -v src="$NFS_SOURCE" -v path="$LOCAL_MOUNT_MEDIA_PATH" '$1 !~ /^#/ && $1 == src && $2 == path { found=1 } END { exit !found }' /etc/fstab; then
    echo -e "      ${YELLOW}-> An entry for ${NFS_SOURCE} -> ${LOCAL_MOUNT_MEDIA_PATH} already exists in /etc/fstab, skipping.${NC}"
else
    # Remove stale entries for this mount point before adding the current configuration
    TMP_FSTAB="$(mktemp)"
    awk -v path="$LOCAL_MOUNT_MEDIA_PATH" '$1 ~ /^#/ || $2 != path' /etc/fstab > "$TMP_FSTAB"
    echo "$FSTAB_ENTRY" >> "$TMP_FSTAB"

    # Back up the current fstab before replacing it with the updated configuration
    sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    sudo install -m 644 "$TMP_FSTAB" /etc/fstab
    rm -f "$TMP_FSTAB"

    echo -e "      ${GREEN}-> Entry added to /etc/fstab.${NC}"
fi

echo -e "${GREEN}NFS setup complete.${NC}"
