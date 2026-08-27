#!/bin/bash
# Main entrypoint to manage the WireGuard stack (start/stop/logs/peers/updates).
# Run manually from the project root, e.g. ./wireguard.sh start.

cd "$(dirname "$0")" || exit

case "$1" in
    start)
        docker compose up -d
        ;;
    stop)
        docker compose down
        ;;
    restart)
        docker compose restart
        ;;
    status)
        docker compose ps
        ;;
    logs)
        docker compose logs -f
        ;;
    handshake)
        docker exec -it wireguard wg show
        ;;
    regenerate)
        ./scripts/regenerate-configs.sh
        ;;
    qr)
        if [ -z "$2" ]; then
            echo "Error: Specify the peer number or name. E.g.: ./wireguard.sh qr 1"
            exit 1
        else
            docker exec -it wireguard /app/show-peer "$2"
        fi
        ;;
    conf-file)
        if [ -z "$2" ]; then
            echo "Error: Specify the peer number or name. E.g.: ./wireguard.sh conf-file 1"
            exit 1
        else
            # Mirrors the image's own /app/show-peer naming: peer<N> for numeric, peer_<name> for named.
            if [[ "$2" =~ ^[0-9]+$ ]]; then
                PEER_ID="peer$2"
            elif [[ "$2" =~ ^[[:alnum:]_-]+$ ]]; then
                PEER_ID="peer_$2"
            else
                echo "Error: peer name must only contain letters, numbers, '_' or '-' (got: '$2')"
                exit 1
            fi
            docker exec wireguard cat "/config/$PEER_ID/$PEER_ID.conf"
        fi
        ;;
    update)
        source ./scripts/lib/update-images.sh
        update_compose_images ./docker-compose.yml "$2"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|handshake|regenerate|qr <num|name>|conf-file <num|name>|update [--yes]}"
        exit 1
        ;;
esac