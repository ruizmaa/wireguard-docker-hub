#!/bin/bash
# Shared --force flag parser for generate-*.sh scripts. Not meant to be run directly.
# Usage: source this file, then call parse_force_flag "$@"; sets $FORCE to "true"/"false".

# Only --force is supported, any other flag is a typo and should fail loudly
# shellcheck disable=SC2034 # FORCE is read by the script that sourced this file, not here
parse_force_flag() {
    FORCE="false"
    local arg
    for arg in "$@"; do
        case "$arg" in
            --force) FORCE="true" ;;
            *) echo "Error: unknown flag '$arg'"; exit 1 ;;
        esac
    done
}

# Refuses to continue if $1 already exists and --force wasn't passed
refuse_overwrite_without_force() {
    local file="$1"
    if [ -f "$file" ] && [ "$FORCE" != "true" ]; then
        echo -e "${RED}Error: $file already exists. Pass --force to overwrite it.${NC}"
        exit 1
    fi
}
