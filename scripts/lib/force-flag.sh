#!/bin/bash
# Shared --force flag parser for generate-*.sh scripts. Not meant to be run directly.
# Usage: source this file, then call parse_force_flag "$@"; sets $FORCE to "true"/"false".

# Only --force is supported, any other flag is a typo and should fail loudly
parse_force_flag() {
    # shellcheck disable=SC2034 # read by the script that sourced this file, not here
    FORCE="false"
    local arg
    for arg in "$@"; do
        case "$arg" in
            # shellcheck disable=SC2034 # read by the script that sourced this file, not here
            --force) FORCE="true" ;;
            *) echo "Error: unknown flag '$arg'"; exit 1 ;;
        esac
    done
}
