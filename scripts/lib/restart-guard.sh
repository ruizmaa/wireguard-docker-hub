#!/bin/bash
# Shared "stop the real service now, restart it on exit if it was running" logic for
# generate-*-config.sh scripts. Not meant to be run directly.
# Usage: source this file (after colors.sh, uses $YELLOW/$RED/$NC), then:
#   WAS_RUNNING=$(stop_service_if_running "$COMPOSE_FILE" <service> "<reason, e.g. 'new config'>")
#   trap 'restart_service_if_was_running "$COMPOSE_FILE" <service> "$WAS_RUNNING"' EXIT

# Stops <service> now if it's running. Prints "true"/"false" on stdout (capture it);
# all human-readable output goes to stderr so it doesn't end up in that captured value.
stop_service_if_running() {
    local compose_file="$1" service="$2" reason="$3" id
    # Get the container's ID, if it's currently running, to know whether to stop/restart it below
    if ! id=$(docker compose -f "$compose_file" ps -q "$service"); then
        echo -e "${RED}Error: 'docker compose ps' failed. Check .env is fully filled in.${NC}" >&2
        exit 1
    fi
    # It's running stop it now, and flag it (via the printed "true") so the caller's cleanup() restarts it
    if [ -n "$id" ]; then
        echo -e "${YELLOW}-> Stopping the running $service container so the $reason takes effect...${NC}" >&2
        # Explicit exit, `set -e` alone won't abort the caller from inside a command substitution
        if ! docker compose -f "$compose_file" stop "$service" >&2; then
            echo -e "${RED}Error: failed to stop $service. Aborting before its config is touched.${NC}" >&2
            exit 1
        fi
        echo "true"
    else
        echo "false"
    fi
}

# Restarts <service> if $3 is "true" (the value stop_service_if_running printed earlier).
restart_service_if_was_running() {
    local compose_file="$1" service="$2" was_running="$3"
    if [ "$was_running" = "true" ]; then
        echo -e "${YELLOW}-> Restarting $service...${NC}"
        docker compose -f "$compose_file" start "$service" || echo -e "${RED}Error: failed to restart $service. Start it manually with 'docker compose start $service'.${NC}"
    fi
}
