#!/bin/bash
# Shared root-owned-path guards for generate-*.sh scripts. Not meant to be run directly.
# Usage: source this file (after colors.sh, uses $RED/$NC), then call the functions below.

# Catches a root-owned dir before the caller's real work reaches it and fails confusingly
guard_writable_dir() {
    local dir="$1"
    if [ -e "$dir" ] && { [ ! -d "$dir" ] || [ ! -w "$dir" ]; }; then
        echo -e "${RED}Error: $dir exists but isn't a writable directory.${NC}"
        echo "This usually means 'docker compose up' ran before this script and Docker auto-created it as root."
        echo "Fix it with: sudo chown -R \"\$(id -u):\$(id -g)\" \"$dir\""
        exit 1
    fi
}

# Catches a stale root-owned file left inside an otherwise-fixed dir (e.g. a partial chown without -R)
guard_writable_file() {
    local file="$1"
    if [ -e "$file" ] && [ ! -w "$file" ]; then
        echo -e "${RED}Error: $file exists but isn't writable.${NC}"
        echo "This usually means 'docker compose up' ran before this script and Docker auto-created it as root."
        echo "Fix it with: sudo chown \"\$(id -u):\$(id -g)\" \"$file\""
        exit 1
    fi
}
