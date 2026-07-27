#!/bin/bash

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
            echo "Error: Specify the peer number. E.g.: ./wireguard.sh qr 1"
            exit 1
        else
            docker exec -it wireguard /app/show-peer "$2"
        fi
        ;;
    conf-file)
        if [ -z "$2" ]; then
            echo "Error: Specify the peer number. E.g.: ./wireguard.sh conf-file 1"
            exit 1
        else
            docker exec -it wireguard cat /config/peer_"$2"/peer"$2".conf
        fi
        ;;
    update)
        source ./scripts/lib/update-images.sh
        update_compose_images ./docker-compose.yml "$2"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|handshake|regenerate|qr <num>|conf-file <num>|update [--yes]}"
        exit 1
        ;;
esac