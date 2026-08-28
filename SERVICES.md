# Home server services

This document details the deployment of dockerized self-hosted services running on your local Home Server.

## Prerequisites

### Basic installation

Run the same installer used on the VPS:

```bash
sudo ./scripts/basic-install.sh
```

This installs Docker Engine and the Compose plugin, `jq` (required by `services/update.sh` and the automated deploy to read the pinned image tags from `services/docker-compose.yml`), enables `fail2ban` for SSH brute-force protection, disables root SSH login, and enables `unattended-upgrades` for automatic security patches.

### Connect to the VPS tunnel

The home server is itself just another WireGuard peer: the VPS forwards traffic from your roaming devices (phone, laptop) to it through the tunnel shown in the [README diagram](README.md). Without this, roaming clients can't reach the services below, and the [trusted-device LAN restriction](#restricting-lan-access-to-trusted-devices) has no VPN traffic to exempt.

Run this from a third, admin device that has SSH access to both the home server and the VPS. Each host can be either a plain `user@ip` or an alias from that device's `~/.ssh/config`:

```bash
./services/install-wireguard.sh <home-server-ssh-host> <vps-ssh-host> <peer-name>
```

This installs `wireguard`/`resolvconf` on the home server if missing, fetches this peer's config straight from the VPS (`./wireguard.sh conf-file <peer-name>` there) instead of you hand-editing `wg0.conf`, and installs/reloads it on the home server as `/etc/wireguard/wg0.conf` — backing up the previous file first if one already exists. It prints `wg show` at the end so you can confirm the handshake.

- Pass `--dry-run` to see what would change (with keys censored) without applying it, e.g. to detect drift after the VPS regenerates this peer.
- Pass `--yes` to skip the confirmation prompt, e.g. for unattended re-syncs.

> [!NOTE]
> The generated peer config uses the same `ALLOWEDIPS` as your phone/laptop (full tunnel, `0.0.0.0/0,::/0` by default). Once the tunnel is up, **all** of the home server's own outbound traffic (Docker pulls, `apt`, Pi-hole's upstream DNS...) routes through the VPS too, not just VPN-bound traffic. If you'd rather keep the home server's own internet access on its normal connection, edit the `AllowedIPs` line under `[Peer]` in `/etc/wireguard/wg0.conf` down to just the VPN subnet (the VPS's `INTERNAL_SUBNET`, e.g. `10.13.13.0/24`) before enabling the service.
>
> `install-wireguard.sh` always fetches the VPS's default (full-tunnel) `AllowedIPs`, since it has no way to know you narrowed it locally. If you later re-sync after the VPS regenerates this peer, the script will stop and ask for confirmation specifically because `AllowedIPs` changed, even under `--yes`. Re-narrow it again by hand after applying if you still want the split-tunnel behavior.

## Services

The services are defined in `services/docker-compose.yml`. Copy the services you need to your main `docker-compose.yml` or run them directly from that directory.

Copy `.env.example` (repo root) to `.env` in this directory and set `PUID`/`PGID`/`TZ` plus your real Syncthing (`SYNCTHING_MOUNT_1`, `SYNCTHING_MOUNT_2`, etc.) and Jellyfin (`JELLYFIN_MEDIA_1`, `JELLYFIN_MEDIA_2`, etc.) data mounts, each a full `host_path:container_path`.

The host ports (`ADGUARD_WEB_PORT`, `ADGUARD_DNS_PORT`, `JELLYFIN_WEB_PORT`, `JELLYFIN_DISCOVERY_PORT`, `SYNCTHING_WEB_PORT`, `SYNCTHING_SYNC_PORT`, `SYNCTHING_DISCOVERY_PORT`) are optional. Leave them out to use the defaults shown in `.env.example`, or set them if you need these services on different ports.

Start the services:

```bash
docker compose up -d
```

Check the status:

```bash
docker compose ps
```

---

### [AdGuard Home](https://hub.docker.com/r/adguard/adguardhome)

A DNS server that blocks ads/trackers and resolves your own service names (`*.home.arpa`).

> [!NOTE]
> Nothing forces any device to use AdGuard for DNS. It only protects/resolves for whichever devices you point at it yourself (manually, per device). The rest of your network keeps using its normal DNS untouched. If you want it network-wide instead, set it as the DNS server in your router's DHCP settings.
>
> If you enable [trusted-device LAN restriction](#restricting-lan-access-to-trusted-devices), only your trusted devices and VPN clients can reach AdGuard (DNS included, not just the admin panel). Relevant only if you pointed other LAN devices at it.

#### AdGuard **Configuration**

- Web interface (day-to-day admin): `http://<SERVER_IP>:8080`
- Persistent data (both bind mounts, owned by UID/GID `1000:1000`, see `user:` in the compose file): `services/adguard/conf/` (`AdGuardHome.yaml`), `services/adguard/work/` (blocklists, query log, stats)

> [!IMPORTANT]
> Before the first `docker compose up`, run:
>
> ```bash
> ./services/generate-adguard-config.sh
> ```
>
> Prompts for an admin username/password (hidden input, 8+ characters), then generates `services/adguard/conf/AdGuardHome.yaml` for you. Web port `80`/DNS port `53` on all interfaces. Skips AdGuard's own first-run wizard entirely: DNS and the web UI are live immediately on first boot. Re-run with `--force` to regenerate it (e.g. to change the password).
>
> Everything except the password comes from the tracked `services/adguard/AdGuardHome.yaml.template` (see [Tracking your config](#tracking-your-config) below).

#### AdGuard **Start**

Log in at `http://<SERVER_IP>:8080` with the username/password you gave the script above, then configure:

- **Upstream DNS Servers** (`Settings > DNS settings`): your preferred resolver (e.g. Cloudflare, Quad9).
- **DNS blocklists** (`Filters > DNS blocklists`): AdGuard ships with one enabled by default, add more from its list of curated sources if you want wider coverage than Pi-hole's defaults gave you.
- **Local DNS Records** (`Filters > DNS rewrites`): add `adguard.home.arpa`, `jellyfin.home.arpa` and `syncthing.home.arpa`, each pointing at the home server's LAN IP.

#### Tracking your config

`services/adguard/conf/AdGuardHome.yaml` is rewritten by AdGuard itself on every change (blocklists, rewrites, upstream servers...), including your real password hash. Not something to commit as-is in a public repo.

```bash
./services/snapshot-adguard-config.sh
```

Copies that live file into the tracked `services/adguard/AdGuardHome.yaml.template`, with the password replaced by an obvious placeholder. Review the diff and `git add`/commit it yourself. Next time you run `generate-adguard-config.sh` (e.g. on a reinstall, or to rotate the password), it rebuilds from this template plus a fresh real password, so nothing you configured is lost.

#### Check if AdGuard working

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
