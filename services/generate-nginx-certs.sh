#!/bin/bash
# Generates a wildcard TLS cert for nginx's *.home.arpa subdomains, signed by a local mkcert CA.
# Run once on the home server before the first `docker compose up`.
# Usage: ./services/generate-nginx-certs.sh [--force]
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"
# shellcheck source=scripts/lib/writable-guard.sh
source "$SCRIPT_DIR/../scripts/lib/writable-guard.sh"
# shellcheck source=scripts/lib/force-flag.sh
source "$SCRIPT_DIR/../scripts/lib/force-flag.sh"

CERT_DIR="$SCRIPT_DIR/nginx/certs"
CERT_FILE="$CERT_DIR/cert.pem"
KEY_FILE="$CERT_DIR/key.pem"
CAROOT="$SCRIPT_DIR/nginx/ca"

if ! command -v mkcert >/dev/null 2>&1; then
    echo -e "${RED}Error: mkcert is not installed. See https://github.com/FiloSottile/mkcert#installation${NC}"
    exit 1
fi

parse_force_flag "$@"

guard_writable_dir "$CERT_DIR"

mkdir -p "$CERT_DIR" "$CAROOT"

guard_writable_file "$CERT_FILE"
guard_writable_file "$KEY_FILE"

# Refuse to overwrite an existing cert unless the caller explicitly opted in
refuse_overwrite_without_force "$CERT_FILE"

# CAROOT fixes where mkcert keeps the root CA. Reusing the same directory on every run (instead of
# mkcert's per-user default) is what makes --force renewals below reuse the same CA instead of a new one.
export CAROOT

# Creates the root CA under $CAROOT the first time it's missing, and installs it into this
# machine's trust store. A no-op on later runs, since the CA already exists here.
mkcert -install

# Signed by the CA above instead of self-signed: devices that already trust that CA (imported
# once, see SERVICES.md) automatically trust this cert too, and any future renewal of it.
mkcert -cert-file "$CERT_FILE" -key-file "$KEY_FILE" "*.home.arpa" home.arpa

chmod 600 "$KEY_FILE"  # private key, readable only by the user

echo -e "${GREEN}-> Generated a cert for *.home.arpa at $CERT_DIR, signed by the local CA at $CAROOT.${NC}"
echo "   Import $CAROOT/rootCA.pem as a trusted authority on each device once (see SERVICES.md)."
echo "   Future --force renewals won't need re-importing anything, since the CA stays the same."
