#!/bin/bash
# Generates a self-signed wildcard TLS cert for nginx's *.home.arpa subdomains.
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
DAYS=825

parse_force_flag "$@"

guard_writable_dir "$CERT_DIR"

mkdir -p "$CERT_DIR"

guard_writable_file "$CERT_FILE"
guard_writable_file "$KEY_FILE"

# Refuse to overwrite an existing cert unless the caller explicitly opted in
refuse_overwrite_without_force "$CERT_FILE"

# req: generate a certificate, self-signed directly instead of a request for a real CA (see -x509 below)
# -x509: self-sign the cert instead of producing a CSR to be signed by someone else
# -nodes: no passphrase, so nginx can read the key unattended on container start
# -newkey rsa:2048: generate a fresh 2048-bit RSA key together with the cert
# -days: how many days the certificate stays valid
# -keyout: where to write the private key
# -out: where to write the certificate
# -subj: sets the cert's Common Name without prompting interactively
# -addext subjectAltName: the field browsers actually check, wildcard covers every *.home.arpa subdomain
openssl req -x509 -nodes -newkey rsa:2048 -days "$DAYS" \
    -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -subj "/CN=home.arpa" \
    -addext "subjectAltName=DNS:*.home.arpa,DNS:home.arpa"

chmod 600 "$KEY_FILE"  # private key, readable only by the user

echo -e "${GREEN}-> Generated a self-signed cert for *.home.arpa at $CERT_DIR.${NC}"
echo "   It's self-signed, so browsers will warn until you import $CERT_FILE as a trusted authority on your devices."
