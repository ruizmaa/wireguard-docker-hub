#!/bin/bash
# Polls a container's wg0 interface until a WireGuard handshake appears, or fails after ~60s.
# Used by install-smoke-test.yml, which needs this same wait in three separate steps.
# Usage: wait-for-wg-handshake.sh <container>
set -e

container="$1"

for i in $(seq 1 12); do
    output=$(sudo docker exec "$container" wg show wg0 2>&1) || true
    if echo "$output" | grep -q "latest handshake"; then
        echo "$output"
        echo "handshake confirmed"
        exit 0
    fi
    echo "no handshake yet (attempt $i/12), retrying in 5s..."
    sleep 5
done
echo "$output"
sudo docker logs "$container" || true
echo "no WireGuard handshake after 60s"
exit 1
