#!/bin/bash
# Shared helpers to run apt-get non-interactively, showing its output only on failure. Not meant to be run directly.
# Usage: source this file (after colors.sh, uses $RED/$NC), then run:
#   quiet_unless_error sudo "${NO_INTERACTIVE_APT[@]}" install -y -qq <packages>

# Passed as sudo arguments because sudo drops exported env vars like DEBIAN_FRONTEND
# shellcheck disable=SC2034 # used by scripts that source this file
NO_INTERACTIVE_APT=(DEBIAN_FRONTEND=noninteractive apt-get)

# Runs a command silently, but if it fails prints its full output and keeps its exit code
quiet_unless_error() {
    local log rc=0
    log=$(mktemp)
    "$@" > "$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo -e "${RED}Command failed (exit $rc): $*${NC}" >&2
        cat "$log" >&2
    fi
    rm -f "$log"
    return "$rc"
}
