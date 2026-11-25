#!/bin/bash
# Shared private deploy log for deploy-services.sh and deploy-wireguard.sh. Not meant to be run directly.
# Usage: source this file, then call start_deploy_log <machine> before any output.

DEPLOY_LOG_DIR="$HOME/deploy-logs"

# From here on, all output goes only to ~/deploy-logs/<date>.log; on exit, prints only whether it worked
start_deploy_log() {
    DEPLOY_MACHINE="$1"
    # Only you can read it (logs can show IPs, paths...)
    mkdir -p "$DEPLOY_LOG_DIR"
    chmod 700 "$DEPLOY_LOG_DIR"
    DEPLOY_LOG_NAME="$(date +%F_%H-%M-%S).log"
    # fd 3 keeps the real output (terminal or Actions log) for the final message
    exec 3>&1 > "$DEPLOY_LOG_DIR/$DEPLOY_LOG_NAME" 2>&1
    trap 'finish_deploy_log $?' EXIT
}

# Prints the result and the log's path, keeps the last 50 logs, then exits with <status>
finish_deploy_log() {
    local status="$1" logs
    if [ "$status" -eq 0 ]; then
        echo "Deploy OK, details in ~/deploy-logs/$DEPLOY_LOG_NAME on the $DEPLOY_MACHINE" >&3
    else
        # ::error:: shows it in red on the Actions run
        echo "::error::Deploy failed, details in ~/deploy-logs/$DEPLOY_LOG_NAME on the $DEPLOY_MACHINE" >&3
    fi
    # Only the last 50 deploys kept (names sort by date)
    logs=("$DEPLOY_LOG_DIR"/*.log)
    [ "${#logs[@]}" -le 50 ] || rm -- "${logs[@]:0:${#logs[@]}-50}"
    exit "$status"
}
