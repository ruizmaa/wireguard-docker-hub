#!/bin/bash
# Builds the CA bundle Homepage's Proxmox/PBS widgets verify against, at services/homepage-certs/.
# Run once on the home server, and again whenever Proxmox or PBS regenerates its certificate.
# Usage: ./services/generate-proxmox-ca.sh [--force]
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"
# shellcheck source=scripts/lib/writable-guard.sh
source "$SCRIPT_DIR/../scripts/lib/writable-guard.sh"
# shellcheck source=scripts/lib/force-flag.sh
source "$SCRIPT_DIR/../scripts/lib/force-flag.sh"

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

CERT_DIR="$SCRIPT_DIR/homepage-certs"
BUNDLE="$CERT_DIR/proxmox-ca.pem"

parse_force_flag "$@"

# Fails clearly here if .env is incomplete, not with a cryptic docker error later
if ! compose_json=$(docker compose -f "$COMPOSE_FILE" config --format json); then
    echo -e "${RED}Error: 'docker compose config' failed. Check .env is fully filled in.${NC}"
    exit 1
fi

# Read from the rendered compose instead of .env: same values, no quoting pitfalls
PVE1_IP=$(echo "$compose_json" | jq -r '.services.nginx.environment.PVE1_IP // empty')
PVE2_IP=$(echo "$compose_json" | jq -r '.services.nginx.environment.PVE2_IP // empty')
PBS_IP=$(echo "$compose_json" | jq -r '.services.nginx.environment.PBS_IP // empty')
PBS_CERT_HOST=$(echo "$compose_json" | jq -r '.services.homepage.environment.HOMEPAGE_VAR_PBS_HOST // empty')
IMAGE=$(echo "$compose_json" | jq -r '.services.homepage.image')

for var in PVE1_IP PBS_IP PBS_CERT_HOST; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: $var is empty. Set it in .env (see .env.example).${NC}"
        exit 1
    fi
done

guard_writable_dir "$CERT_DIR"
mkdir -p "$CERT_DIR"
guard_writable_file "$BUNDLE"

# Refuse to overwrite an existing bundle unless the caller explicitly opted in
refuse_overwrite_without_force "$BUNDLE"

TMP_CA=$(mktemp)
trap 'rm -f "$TMP_CA"' EXIT

# One CA signs every node in a cluster, so any node serves it. Standalone nodes each have
# their own: run this once per node and concatenate if yours aren't clustered.
echo -e "${CYAN}-> Copying the PVE cluster CA from $PVE1_IP (asks for that node's root password)...${NC}"
if ! scp -q "root@$PVE1_IP:/etc/pve/pve-root-ca.pem" "$TMP_CA"; then
    echo -e "${RED}Error: couldn't copy /etc/pve/pve-root-ca.pem from $PVE1_IP.${NC}"
    echo "Copy it over manually and re-run, or check SSH access to that node."
    exit 1
fi

# PBS signs its own cert, so the cert itself is the anchor and there's no CA to fetch
echo -e "${CYAN}-> Reading PBS's self-signed cert off $PBS_IP:8007...${NC}"
if ! pbs_cert=$(echo | openssl s_client -connect "$PBS_IP:8007" 2>/dev/null | openssl x509); then
    echo -e "${RED}Error: couldn't read a certificate from $PBS_IP:8007. Is PBS up?${NC}"
    exit 1
fi

{ cat "$TMP_CA"; echo "$pbs_cert"; } > "$BUNDLE"

# Prove the bundle actually validates before homepage depends on it: same image, same
# fetch() the widgets use, so a pass here means the widgets will verify too
echo -e "${CYAN}-> Verifying the bundle against each backend...${NC}"
targets="[[\"pve1\",\"https://$PVE1_IP:8006\"]"
[ -n "$PVE2_IP" ] && targets="$targets,[\"pve2\",\"https://$PVE2_IP:8006\"]"
targets="$targets,[\"pbs\",\"https://$PBS_CERT_HOST:8007\"]]"

# A 401 is a pass: no token is sent here, this only measures whether TLS verifies
node_check="const t=$targets;(async()=>{let bad=0;for(const[n,u]of t){try{const r=await fetch(u+'/api2/json/version');console.log('   '+n+' verified (http '+r.status+')')}catch(e){console.log('   '+n+' FAILED: '+(e.cause?.code||e.message));bad++}}process.exit(bad?1:0)})()"

if ! docker run --rm --entrypoint node \
    -v "$CERT_DIR:/certs:ro" \
    --add-host "$PBS_CERT_HOST:$PBS_IP" \
    -e NODE_EXTRA_CA_CERTS=/certs/proxmox-ca.pem \
    "$IMAGE" -e "$node_check"; then
    echo -e "${RED}Error: the bundle doesn't verify every backend. The widgets would show 'API Error'.${NC}"
    echo "A node that fails here regenerated its cert, or serves a name that isn't in its SAN."
    exit 1
fi

echo -e "${GREEN}-> Wrote $BUNDLE, verified against every backend.${NC}"
echo "   PBS is reached as $PBS_CERT_HOST, the name in its cert, mapped to $PBS_IP by the compose file."

# If homepage is already up, recreate it: `restart` alone won't remount the bundle
if [ -n "$(docker compose -f "$COMPOSE_FILE" ps -q homepage 2>/dev/null)" ]; then
    echo -e "${YELLOW}-> Recreating homepage to pick up the new bundle...${NC}"
    docker compose -f "$COMPOSE_FILE" up -d homepage || echo -e "${RED}Error: failed to recreate homepage. Run 'docker compose up -d homepage' manually.${NC}"
fi
