#!/bin/bash
# Shared AdGuard `users:` block helpers, used by generate-adguard-config.sh and
# snapshot-adguard-config.sh. Not meant to be run directly.
# Usage: source this file, then call the functions below.

# Prints only the `users:` block, so no other list can be mistaken for it below
users_block() {
    awk '/^users:/{f=1} f && !/^users:/ && /^[^ ]/{exit} f'
}

# Counts admin (`- name:`) entries inside the users: block of a YAML file/stream on stdin
# `|| true`: grep -c exits 1 on a zero count, which would otherwise kill the caller under set -e
count_admin_accounts() {
    users_block | grep -c '^  - name:' || true
}
