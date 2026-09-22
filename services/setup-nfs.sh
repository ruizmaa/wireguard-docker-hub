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
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

echo -e "    ${YELLOW}[1/6] Reading configuration...${NC}"
# Require the services environment file to be present
if [ ! -f "$ENV_FILE" ]; then
    echo -e "    ${RED}-> ERROR: $ENV_FILE not found. Copy .env.example to services/.env and set TRUENAS_IP/TRUENAS_MEDIA_PATH first.${NC}"
    exit 1
fi

TRUENAS_IP=$(read_env TRUENAS_IP "")
TRUENAS_MEDIA_PATH=$(read_env TRUENAS_MEDIA_PATH "")
LOCAL_MOUNT_MEDIA_PATH=$(read_env LOCAL_MOUNT_MEDIA_PATH "/mnt/nas_media")

echo -e "    ${YELLOW}[2/6] Validating configuration...${NC}"
# Ensure the TrueNAS address and remote media path are configured
if [ -z "$TRUENAS_IP" ] || [ -z "$TRUENAS_MEDIA_PATH" ]; then
    echo -e "    ${RED}-> ERROR: TRUENAS_IP or TRUENAS_MEDIA_PATH is empty in $ENV_FILE.${NC}"
    exit 1
fi

# /etc/fstab is whitespace-delimited
for var_name in TRUENAS_IP TRUENAS_MEDIA_PATH LOCAL_MOUNT_MEDIA_PATH; do
    if [[ "${!var_name}" =~ [[:space:]] ]]; then
        echo -e "    ${RED}-> ERROR: $var_name contains whitespace in $ENV_FILE, which /etc/fstab can't represent.${NC}"
        exit 1
    fi
done

# Normalize the path before applying mount-point safety checks
LOCAL_MOUNT_MEDIA_PATH="$(realpath -ms -- "$LOCAL_MOUNT_MEDIA_PATH")"

# Never allow the root filesystem as the mount point
if [ "$LOCAL_MOUNT_MEDIA_PATH" = "/" ]; then
    echo -e "    ${RED}-> ERROR: LOCAL_MOUNT_MEDIA_PATH is '/' in $ENV_FILE. Refusing to use the root filesystem as the NFS mount point.${NC}"
    exit 1
fi

# Never mount the NFS share over a top-level system directory
case "$LOCAL_MOUNT_MEDIA_PATH" in
    /bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
        echo -e "    ${RED}-> ERROR: LOCAL_MOUNT_MEDIA_PATH is '$LOCAL_MOUNT_MEDIA_PATH' in $ENV_FILE, a system directory. Refusing to use it as the NFS mount point.${NC}"
        exit 1
        ;;
esac

NFS_SOURCE="${TRUENAS_IP}:${TRUENAS_MEDIA_PATH}"
# Let systemd mount the share on first access, so Docker bind mounts wait for NFS
# instead of racing the mount and seeing an empty local directory
FSTAB_OPTS="defaults,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=30"
FSTAB_ENTRY="${NFS_SOURCE}  ${LOCAL_MOUNT_MEDIA_PATH}  nfs  ${FSTAB_OPTS}  0  0"

echo "      -> NFS source: $NFS_SOURCE"
echo "      -> Mount point: $LOCAL_MOUNT_MEDIA_PATH"

echo -e "    ${YELLOW}[3/6] Installing NFS client...${NC}"
sudo "${NO_INTERACTIVE_APT[@]}" update -qq > /dev/null
sudo "${NO_INTERACTIVE_APT[@]}" install -y -qq nfs-common > /dev/null

echo -e "    ${YELLOW}[4/6] Configuring NFS mount...${NC}"
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
        # Refuse to unmount out from under running containers that bind-mount this path
        RUNNING_MEDIA_CONTAINERS="$(docker compose -f "$COMPOSE_FILE" ps -q jellyfin qbittorrent radarr sonarr 2>/dev/null)"
        if [ -n "$RUNNING_MEDIA_CONTAINERS" ]; then
            echo -e "      ${RED}-> ERROR: jellyfin/qbittorrent/radarr/sonarr are still using $LOCAL_MOUNT_MEDIA_PATH. Stop the stack first: docker compose -f $COMPOSE_FILE down${NC}"
            exit 1
        fi
        echo "      -> Unmounting stale mount from $CURRENT_SOURCE..."
        sudo umount -l "$LOCAL_MOUNT_MEDIA_PATH"
    # A directory that already has files and isn't our NFS mount would otherwise be silently hidden underneath the new mount
    elif [ -n "$(ls -A "$LOCAL_MOUNT_MEDIA_PATH" 2>/dev/null)" ]; then
        echo -e "      ${RED}-> ERROR: $LOCAL_MOUNT_MEDIA_PATH already contains files and isn't the NFS mount. Refusing to mount over it and hide its contents.${NC}"
        exit 1
    fi

    echo "      -> Checking connectivity to $TRUENAS_IP:2049 (NFS)..."
    # Pass TRUENAS_IP as an argument rather than interpolating it into bash -c,
    # so shell special characters in the value cannot be interpreted as commands
    # shellcheck disable=SC2016
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

echo -e "    ${YELLOW}[5/6] Verifying NFS mount...${NC}"
echo "      -> Contents of $LOCAL_MOUNT_MEDIA_PATH:"

# Show the mounted share contents as a basic access check
ls -la "$LOCAL_MOUNT_MEDIA_PATH" || echo -e "      ${YELLOW}-> WARNING: couldn't list $LOCAL_MOUNT_MEDIA_PATH (permission issue?). The mount itself succeeded.${NC}"

echo -e "    ${YELLOW}Verifying required media directories exist...${NC}"

missing_dirs=()

# Check for missing media directories referenced in the docker-compose.yml file
if [ -f "$COMPOSE_FILE" ]; then
    while IFS= read -r subpath; do
        if [ -n "$subpath" ]; then
            target_dir="$LOCAL_MOUNT_MEDIA_PATH/$subpath"
            if [ ! -d "$target_dir" ]; then
                missing_dirs+=("$subpath")
            fi
        fi
    done < <(grep -v '^[[:space:]]*#' "$COMPOSE_FILE" | grep -oP '\$\{LOCAL_MOUNT_MEDIA_PATH:-[^}]+\}/\K[^:/]+' | sort -u)
fi

# qBittorrent.conf.defaults sets Downloads\SavePath to /media/downloads/ directly, it isn't a compose volume
if [ ! -d "$LOCAL_MOUNT_MEDIA_PATH/downloads" ]; then
    missing_dirs+=("downloads")
fi

# If any required media directories are missing, print an error message and instructions to create them on the TrueNAS server
if [ ${#missing_dirs[@]} -gt 0 ]; then
    echo -e "      ${RED}-> ERROR: The following media directories do not exist on the NFS share:${NC}"
    for dir in "${missing_dirs[@]}"; do
        echo -e "         - $LOCAL_MOUNT_MEDIA_PATH/$dir"
    done
    echo -e "\n      ${YELLOW}Please create them manually on your TrueNAS server by running:${NC}"
    
    # Use the configured TRUENAS_MEDIA_PATH if set, otherwise default to /mnt/tank/media
    truenas_base_path="${TRUENAS_MEDIA_PATH:-/mnt/tank/media}"
    cmd="sudo mkdir -p"
    for dir in "${missing_dirs[@]}"; do
        cmd="$cmd ${truenas_base_path}/$dir"
    done
    echo -e "         ${GREEN}$cmd${NC}\n"
    exit 1
else
    echo -e "      ${GREEN}-> All required media directories exist.${NC}"
fi

echo -e "    ${YELLOW}[6/6] Persisting mount in /etc/fstab...${NC}"

# Skip only if source, mount point AND options already match
# An entry with stale options (e.g. a hand-edited one) falls through to the replace branch instead
if awk -v src="$NFS_SOURCE" -v path="$LOCAL_MOUNT_MEDIA_PATH" -v opts="$FSTAB_OPTS" \
    '$1 !~ /^#/ && $1 == src && $2 == path && $4 == opts { found=1 } END { exit !found }' /etc/fstab; then
    echo -e "      ${YELLOW}-> An entry for ${NFS_SOURCE} -> ${LOCAL_MOUNT_MEDIA_PATH} already exists in /etc/fstab, skipping.${NC}"
else
    # Remove stale entries for this mount point before adding the current configuration
    TMP_FSTAB="$(mktemp)"
    trap 'rm -f "$TMP_FSTAB"' EXIT
    awk -v path="$LOCAL_MOUNT_MEDIA_PATH" '$1 ~ /^#/ || $2 != path' /etc/fstab > "$TMP_FSTAB"
    echo "$FSTAB_ENTRY" >> "$TMP_FSTAB"

    # Back up the current fstab before replacing it with the updated configuration
    sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"

    # Ensure the temporary fstab is not empty before overwriting the system file
    if [ -s "$TMP_FSTAB" ]; then
        sudo install -m 644 "$TMP_FSTAB" /etc/fstab
        rm -f "$TMP_FSTAB"
    else
        echo -e "      ${RED}-> ERROR: temporary fstab is empty, aborting.${NC}"
        rm -f "$TMP_FSTAB"
        exit 1
    fi

    # Regenerate the automount unit from the entry just written
    # Skipped on hosts where systemd isn't actually running as PID 1 (e.g. a container), where it would just fail
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        sudo systemctl daemon-reload
        echo -e "      ${GREEN}-> Entry added to /etc/fstab and systemd reloaded.${NC}"
    else
        echo -e "      ${GREEN}-> Entry added to /etc/fstab.${NC}"
    fi
fi

echo -e "${GREEN}NFS setup complete.${NC}"
