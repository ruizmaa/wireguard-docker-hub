#!/bin/bash
# Library shared by wireguard.sh's `update` subcommand and services/update.sh. Not meant to be run directly.
# Usage (after sourcing): update_compose_images <compose_file> [--yes]

# shellcheck source=scripts/lib/colors.sh
source "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/colors.sh"

update_compose_images() {
    local compose_file="$1"
    local auto_yes="false"
    [ "$2" = "--yes" ] && auto_yes="true"

    local had_failure="false"

    local compose_json
    local compose_err_file
    compose_err_file=$(mktemp)
    if ! compose_json=$(docker compose -f "$compose_file" config --format json 2>"$compose_err_file"); then
        echo -e "  ${RED}[FAIL]${NC} '$compose_file': docker compose config failed:"
        # shellcheck disable=SC2001 # clearer here than parameter-expansion for multi-line indent
        sed 's/^/        /' "$compose_err_file"
        rm -f "$compose_err_file"
        return 1
    fi
    rm -f "$compose_err_file"

    local service_list
    if ! service_list=$(echo "$compose_json" | jq -r '.services | to_entries[] | "\(.key)\t\(.value.image)\t\(.value.container_name)"' 2>&1); then
        echo -e "  ${RED}[FAIL]${NC} could not parse services from '$compose_file' (is jq installed?): $service_list"
        return 1
    fi

    while IFS=$'\t' read -r service desired_image container_name; do
        local current_image
        current_image=$(docker inspect --format '{{.Config.Image}}' "$container_name" 2>/dev/null) || {
            echo -e "  ${YELLOW}[WARN]${NC} $service: container '$container_name' not found or not running, skipping"
            continue
        }

        if [ "$current_image" = "$desired_image" ]; then
            echo -e "  ${GREEN}[ OK ]${NC} $service: up to date ($desired_image)"
            continue
        fi

        echo -e "  ${YELLOW}[NEW ]${NC} $service: $current_image -> $desired_image"

        local proceed="false"
        if [ "$auto_yes" = "true" ]; then
            proceed="true"
        else
            read -r -p "        Update $service? [y/N] " answer
            case "$answer" in
                [Yy]*) proceed="true" ;;
            esac
        fi

        if [ "$proceed" != "true" ]; then
            echo "        Skipped."
            continue
        fi

        if docker compose -f "$compose_file" pull "$service" && docker compose -f "$compose_file" up -d "$service"; then
            echo -e "  ${GREEN}[ OK ]${NC} $service updated"
        else
            echo -e "  ${RED}[FAIL]${NC} $service: update failed"
            had_failure="true"
        fi
    done <<< "$service_list"

    [ "$had_failure" = "true" ] && return 1
    return 0
}
