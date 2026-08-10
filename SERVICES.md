# Home server services

This document details the deployment of dockerized self-hosted services running on your local Home Server.

## Prerequisites

### Basic installation

Run the same installer used on the VPS:

```bash
sudo ./scripts/basic-install.sh
```

This installs Docker Engine and the Compose plugin, `jq` (required by `services/update.sh` and the automated deploy to read the pinned image tags from `services/docker-compose.yml`), enables `fail2ban` for SSH brute-force protection, disables root SSH login, and enables `unattended-upgrades` for automatic security patches.

## Services

The services are defined in `services/docker-compose.yml`. Copy the services you need to your main `docker-compose.yml` or run them directly from that directory.

Copy `.env.example` (repo root) to `.env` in this directory and set `PUID`/`PGID`/`TZ` plus your real Syncthing (`SYNCTHING_MOUNT_1`, `SYNCTHING_MOUNT_2`, etc.) and Jellyfin (`JELLYFIN_MEDIA_1`, `JELLYFIN_MEDIA_2`, etc.) data mounts, each a full `host_path:container_path`.

The host ports (`PIHOLE_WEB_PORT`, `PIHOLE_DNS_PORT`, `HOMEPAGE_WEB_PORT`, `JELLYFIN_WEB_PORT`, `JELLYFIN_DISCOVERY_PORT`, `SYNCTHING_WEB_PORT`, `SYNCTHING_SYNC_PORT`, `SYNCTHING_DISCOVERY_PORT`) are optional. Leave them out to use the defaults shown in `.env.example`, or set them if you need these services on different ports.

Start the services:

```bash
docker compose up -d
```

Check the status:

```bash
docker compose ps
```

---

### [Homepage](https://github.com/gethomepage/homepage)

A highly customizable homepage with quick access to all your self-hosted services.

#### Homepage **Configuration**

- Web interface: `http://<SERVER_IP>:3000`
- Config directory (bind mount): `services/homepage/` → `/app/config`

> [!IMPORTANT]
> Set `HOMEPAGE_ALLOWED_HOSTS` in `.env` to the host[:port] you access Homepage from (its LAN IP, e.g. `192.168.1.10:3000`, and its WireGuard tunnel IP, e.g. `10.13.13.2:3000`, if you also reach it over the VPN). Without it, the dashboard page loads but every widget (resources, service status, search suggestions...) fails with a "Host validation failed" error, since Homepage only trusts `localhost` by default for its internal API calls.

All customization is done through YAML files inside `services/homepage/`, which are tracked in this repository:

| File | Purpose |
|---|---|
| `services.yaml` | Define the service cards shown on the dashboard |
| `bookmarks.yaml` | Shortcut links |
| `widgets.yaml` | Top-bar info widgets (date, search, resources…) |
| `settings.yaml` | Global settings (title, theme, layout…) |

Edit those files, commit the changes, and restart the container to apply them:

```bash
docker compose restart homepage
```

#### Homepage **Start**

Open the web UI at `http://<SERVER_IP>:3000`. The default page is ready to use out of the box. Edit the YAML files in `services/homepage/` to add your services, bookmarks and widgets, then commit the changes.

---

### [Pi-hole](https://hub.docker.com/r/pihole/pihole)

A DNS sinkhole that protects your devices from unwanted content.

> [!NOTE]
> If you enable [trusted-device LAN restriction](#restricting-lan-access-to-trusted-devices), only your trusted devices and VPN clients can use Pi-hole (DNS included, not just the admin panel). The rest of your network won't be able to reach it.

#### Pi-hole **Configuration**

- Web interface: `http://<SERVER_IP>:8080/admin`
- Persistent data (Docker volume): `pihole_etc` (mounted at `/etc/pihole`)

##### Pi-hole **Password**

You can set your own password by editing the docker compose, just uncomment the `WEBPASSWORD` environment variable and write your own password.

If you don't specify your password, it will be generated randomly, the easiest way to change it is using this command:

```bash
docker exec -it pihole pihole setpassword
```

#### Pi-hole **Start**

Go to `http://<SERVER_IP>:8080/admin` and log in with your password.

Configure your **Upstream DNS Servers** and **Interface Settings** (allow traffic from the Docker container and your local net):

1. Go to `Settings > DNS`
2. Go to `Upstream DNS Servers`, select your preferred provider
3. Go to `Interface settings`, select Potentially dangerous options > `Permit all origins`
4. Save

Update **Blocklists** (Gravity) to ensure Pi-hole knows which ads to block:

1. Go to `Tools > Update Gravity`
2. Click the `Update` button

>You can also use this command:
>
>`docker exec -it pihole pihole -g`

#### Check if Pi-hole working

Check if unwanted traffic is blocked:

```bash
nslookup flurry.com
```

You should read something like this:

```text
Server:     127.0.0.53
Address:    127.0.0.53#53

Non-authoritative answer:
Name:   flurry.com
Address: 0.0.0.0
Name:   flurry.com
Address: ::

```

Check if desired traffic is allowed:

```bash
nslookup google.com
```

This should show something like this:

```text
Server:     127.0.0.53
Address:    127.0.0.53#53

Non-authoritative answer:
Name:   google.com
Address: 142.250.184.174
Name:   google.com
Address: 2a00:1450:4003:803::200e
```

### [Syncthing](https://hub.docker.com/r/linuxserver/syncthing)

A continuous file synchronization program.

#### Syncthing **Configuration**

- Web interface: `http://<SERVER_IP>:8384`

##### Syncthing **Password**

By default, the Syncthing web interface is accessible without any credentials, so it's highly recommended to set a username and password.

Open the web UI at `http://<SERVER_IP>:8384` and go to: `Actions > Settings > GUI > Set user/password`. Here add your username and password. It's also recommended to activate the option `Use HTTPS for GUI`.

#### Syncthing **Start**

Once it's running, you can start syncing files by following these steps:

> Following the `docker-compose.yml` file, the example file paths used in `volumes` are `/path/to/data1:/data1`

1. **Map the folders:** syncthing synchronizes entire folders, not individual files.
    - **Host:** place your files in the local directory (`/path/to/data1`)
    - **Container:** in the Web UI, refer to this folder using the internal path defined in your Docker Compose (`/data1`)

2. **Add Folder in Web UI:**
    1. Open the web UI at `http://<SERVER_IP>:8384`
    2. Click  `Add folder`
    3. `Folder path`: Enter the container path (`/data1`).
    4. Go to `Sharing` tab and check the devices you want to sync with

3. **Link devices:**
    1. Get the `Device ID` from your phone/laptop.
    2. In the MiniPC Web UI, click `Add Remote Device` and paste the ID.
    3. Accept the connection on both ends.

Any file moved into the local folder on your MiniPC will automatically appear on the linked devices.

Changes are bidirectional: if you edit or delete a file on one device, it will be updated on all others.

### [Jellyfin](https://hub.docker.com/r/linuxserver/jellyfin)

A media server for streaming your personal video, audio and photo collections to apps and browsers.

#### Jellyfin **Configuration**

- Web interface: `http://<SERVER_IP>:8096`
- Auto-discovery (DLNA/clients): UDP `7359`
- Persistent volumes:
  - `jellyfin_config` → `/config`
  - `jellyfin_cache`  → `/cache`
- Media path: map your host directories to `/media` (e.g. `/mnt/hdd/movies:/media`)

> Set `JELLYFIN_MEDIA_1` (and `JELLYFIN_MEDIA_2`, etc.) in `.env` to your actual media library path, as a full `host_path:container_path` (e.g. `/mnt/hdd/movies:/media`).

## Restricting LAN access to trusted devices

By default, SSH and the services are reachable from any device on your home network. `scripts/fix-home-net.sh` restricts them to a fixed list of trusted devices only, without affecting VPN access (WireGuard-tunneled traffic is always trusted, since it's already authenticated by the peer's key).

1. Give your trusted devices a DHCP reservation on your router, so their IPs don't change.
2. Find each device's MAC address (in its own network settings, or your router's DHCP/client list) and set `TRUSTED_LAN_DEVICES` in `services/.env` to a comma-separated list of `IP@MAC` pairs, no spaces. Both have to match:

   ```bash
   TRUSTED_LAN_DEVICES=192.168.1.1@aa:bb:cc:dd:ee:ff,192.168.1.2@11:22:33:44:55:66
   ```

3. Run the script:

   ```bash
   sudo ./scripts/fix-home-net.sh
   ```

To add or remove a device, edit `TRUSTED_LAN_DEVICES` and re-run the script. It rebuilds the allowlist from scratch each time, so it always matches exactly what's currently in `.env`.

If you change the SSH port, re-run the script too. It reads the live SSH port each time it runs and bakes that value into the rule, so the old port stays enforced until you do.

Adding a new service or changing a port doesn't need a re-run. Docker-published services are gated by NAT state, not by a list of specific ports, so any current or future published port is already covered.

This also blocks IPv6 entirely on the home server: nothing in this project needs it (the WireGuard tunnel is IPv4-only) and IPv6 addresses can change on their own, unlike a DHCP-reserved IPv4. So there's no stable identifier to allowlist against.

> [!WARNING]
> If a trusted device's IP or MAC ever changes, you'll lose LAN access to SSH too. The WireGuard tunnel is unaffected by this allowlist, so you can always fall back to connecting through the VPN to fix it.

The script also pings each device and warns (without blocking) if it doesn't answer or answers with a different MAC. Repeated again at the end of the output too.

`fix-home-net.sh` finishes by running `scripts/check-network-config-home.sh`, which reports the status of every rule it just applied. You can also run it on its own at any time, without touching the firewall, to check the current state:

```bash
sudo ./scripts/check-network-config-home.sh
```
