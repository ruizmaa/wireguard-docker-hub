#!/bin/bash
# Library shared by fix-home-net.sh and check-network-config-home.sh for reading services/.env. Not meant to be run directly
# Usage (after sourcing, with ENV_FILE set): read_env KEY [default]

# Reads KEY from $ENV_FILE, stripping a wrapping pair of quotes if present, or $2 if unset/empty
read_env() {
    local value
    value=$(grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2-) || true
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
    fi
    echo "${value:-$2}"
}
