#!/bin/bash
# Enumerates the "<service>.home.arpa" hostnames nginx proxies to, one per line.
# Used by install-smoke-test.yml, which needs this same list in two separate steps.
# Usage: nginx-proxied-hosts.sh <conf.d-dir> [name-to-exclude ...]
set -e

dir="$1"; shift
exclude=("default" "$@")

for f in "$dir"/*.conf.template; do
    name=$(basename "$f" .conf.template)
    skip=0
    for e in "${exclude[@]}"; do
        [ "$name" = "$e" ] && skip=1 && break
    done
    [ "$skip" = 1 ] && continue
    echo "$name.home.arpa"
done
