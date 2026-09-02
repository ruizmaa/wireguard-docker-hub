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
> The generated peer config uses the same `ALLOWEDIPS` as your phone/laptop (full tunnel, `0.0.0.0/0,::/0` by default). Once the tunnel is up, **all** of the home server's own outbound traffic (Docker pulls, `apt`, AdGuard's upstream DNS...) routes through the VPS too, not just VPN-bound traffic. If you'd rather keep the home server's own internet access on its normal connection, edit the `AllowedIPs` line under `[Peer]` in `/etc/wireguard/wg0.conf` down to just the VPN subnet (the VPS's `INTERNAL_SUBNET`, e.g. `10.13.13.0/24`) before enabling the service.
>
> `install-wireguard.sh` always fetches the VPS's default (full-tunnel) `AllowedIPs`, since it has no way to know you narrowed it locally. If you later re-sync after the VPS regenerates this peer, the script will stop and ask for confirmation specifically because `AllowedIPs` changed, even under `--yes`. Re-narrow it again by hand after applying if you still want the split-tunnel behavior.

## Services

The services are defined in `services/docker-compose.yml`. Copy the services you need to your main `docker-compose.yml` or run them directly from that directory.

Copy `.env.example` (repo root) to `.env` in this directory and set `PUID`/`PGID`/`TZ` plus your real Syncthing (`SYNCTHING_MOUNT_1`, `SYNCTHING_MOUNT_2`, etc.) and Jellyfin (`JELLYFIN_MEDIA_1`, `JELLYFIN_MEDIA_2`, etc.) data mounts, each a full `host_path:container_path`.

The host ports (`NGINX_HTTP_PORT`, `NGINX_HTTPS_PORT`, `ADGUARD_WEB_PORT`, `ADGUARD_DNS_PORT`, `ADGUARD_SETUP_PORT`, `HOMEPAGE_WEB_PORT`, `JELLYFIN_WEB_PORT`, `JELLYFIN_DISCOVERY_PORT`, `SYNCTHING_WEB_PORT`, `SYNCTHING_SYNC_PORT`, `SYNCTHING_DISCOVERY_PORT`) are optional. Leave them out to use the defaults shown in `.env.example`, or set them if you need these services on different ports.

`LAN_SUBNET` and `VPN_SUBNET` are required for [nginx](#nginx-reverse-proxy). `HOMEPAGE_ALLOWED_HOSTS`, `HOME_SERVER_HOST` and `HOME_SERVER_WG_HOST` are required for [Homepage](#homepage). `docker compose up` refuses to start the whole stack if any of these are missing.

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

- Web interface: `http://<SERVER_IP>:3001`
- Config directory (bind mount): `services/homepage/` → `/app/config`

> [!IMPORTANT]
> Set `HOMEPAGE_ALLOWED_HOSTS`, `HOME_SERVER_HOST` and `HOME_SERVER_WG_HOST` in `.env`. All three are required: `docker compose up` refuses to start the whole stack if any is missing.
>
> - `HOMEPAGE_ALLOWED_HOSTS`: every host[:port] you access Homepage from, comma-separated (e.g. `192.168.1.X:3001` for its LAN IP, plus `10.13.13.X:3001` for its WireGuard tunnel IP if you also reach it over the VPN). This is a security allowlist: whichever address you type in your browser is sent as the `Host` header, and Homepage only trusts `localhost` by default for its internal API calls. So every widget (resources, service status, search suggestions...) would otherwise fail with a "Host validation failed" error.
> - `HOME_SERVER_HOST`: this machine's LAN IP (e.g. `192.168.1.X`). Baked into the "(LAN)" AdGuard/Jellyfin/Syncthing service card links shown on the dashboard.
> - `HOME_SERVER_WG_HOST`: this machine's own WireGuard tunnel IP (e.g. `10.13.13.X`, from `INTERNAL_SUBNET`). Baked into the "(VPN)" versions of those same cards, so the links still work when you're accessing Homepage over the VPN — the tunnel has no route to the LAN IP above by default (the home server's peer only has `AllowedIPs` scoped to its own tunnel IP, see the main [README.md](../README.md)), but it always routes to its own tunnel IP.

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

Open the web UI at `http://<SERVER_IP>:3001`. The default page is ready to use out of the box. Edit the YAML files in `services/homepage/` to add your services, bookmarks and widgets, then commit the changes.

---

### [AdGuard Home](https://hub.docker.com/r/adguard/adguardhome)

A DNS server that blocks ads/trackers and resolves your own service names (`*.home.arpa`, see [nginx](#nginx-reverse-proxy) below).

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
> Prompts for an admin username/password (hidden input, 8+ characters), then generates `services/adguard/conf/AdGuardHome.yaml` for you. Web port `80`/DNS port `53` on all interfaces, matching what [nginx](#nginx-reverse-proxy) expects. Skips AdGuard's own first-run wizard entirely: DNS and the web UI are live immediately on first boot. Re-run with `--force` to regenerate it (e.g. to change the password).
>
> If [nginx](#nginx-reverse-proxy) is in use, it also sets up split-horizon DNS for `adguard.home.arpa`/`jellyfin.home.arpa`/`syncthing.home.arpa`, showing what it's about to change before asking for confirmation:
>
> - LAN clients resolve them to this host's LAN IP, found via a route lookup against `LAN_SUBNET` (overridable with `ADGUARD_LAN_IP`, CI sets this).
> - VPN (WireGuard) clients resolve them to this host's own tunnel IP instead, read from its `wg0` interface (overridable with `ADGUARD_VPN_IP`, CI sets this).
>
> No WireGuard changes needed: nginx already listens on `wg0`, so this works without widening the VPS peer's `AllowedIPs` (see [README](README.md)).
>
> Everything except the password comes from the tracked `services/adguard/AdGuardHome.yaml.template` (see [Tracking your config](#tracking-your-config) below).

#### AdGuard **Start**

Log in at `http://<SERVER_IP>:8080` with the username/password you gave the script above, then configure:

- **Upstream DNS Servers** (`Settings > DNS settings`): your preferred resolver (e.g. Cloudflare, Quad9).
- **DNS blocklists** (`Filters > DNS blocklists`): AdGuard ships with one enabled by default, add more from its list of curated sources if you want.

If you're using [nginx](#nginx-reverse-proxy), `generate-adguard-config.sh` already set up `adguard.home.arpa`/`jellyfin.home.arpa`/`syncthing.home.arpa` for you as *Custom filtering rules* (`Filters > Custom filtering rules`), split by LAN/VPN, nothing to do manually.

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

---

### [nginx](https://hub.docker.com/_/nginx) reverse proxy

Instead of remembering a port per service (`:8080`, `:8096`, `:8384`...), nginx puts every service behind its own `https://<service>.home.arpa` address. `home.arpa` is reserved by [RFC 8375](https://www.rfc-editor.org/rfc/rfc8375) for home networks, so it can never collide with a real public domain.

#### nginx **Configuration**

All configuration lives in `services/nginx/templates/`, tracked in this repository:

| File | Purpose |
|---|---|
| `nginx.conf.template` | Main config, defines the LAN/VPN `$zone` split (see [below](#lan-vs-wireguard-zone)) |
| `conf.d/<service>.conf.template` | One server block per service: HTTP->HTTPS redirect, TLS, proxy to that service |
| `conf.d/default.conf.template` | Catches any other host and drops the connection, also serves `/healthz` for the container healthcheck |
| `proxy_params.conf.template` | Headers shared by every proxied service |

These are `.conf.template`, not `.conf`, nginx's own Docker image substitutes `${LAN_SUBNET}`/`${VPN_SUBNET}`/`${NGINX_HTTPS_PORT}` into them and writes the result to `/etc/nginx/` (mirroring this folder's own layout) at container start (`NGINX_ENVSUBST_FILTER` in `docker-compose.yml` restricts substitution to exactly those variables, so it can't touch nginx's own `$host`/`$remote_addr`/etc., which use the same `$` syntax).

> [!IMPORTANT]
> Before the first `docker compose up`, generate a self-signed TLS certificate (one wildcard cert covers all `*.home.arpa` subdomains):
>
> ```bash
> ./services/generate-nginx-certs.sh
> ```
>
> It's self-signed, so browsers will warn until you import `services/nginx/certs/cert.pem` as a trusted authority on each of your devices. Re-run with `--force` to replace it (e.g. once it's close to expiring).
>
> Also set `LAN_SUBNET` and `VPN_SUBNET` in `.env` (see `.env.example`). Your LAN's CIDR, and the VPS's `INTERNAL_SUBNET` as a CIDR, these decide the `lan`/`vpn`/`external` split described below.

Finally, so `<service>.home.arpa` actually resolves: run (or re-run) [`generate-adguard-config.sh`](#adguard-configuration) after this — it sets up split-horizon DNS automatically (LAN clients get this host's LAN IP, VPN clients get its WireGuard tunnel IP).

#### LAN vs. WireGuard zone

nginx computes a `$zone` per request from the client's source IP (`lan`, `vpn`, or `external` for anything outside both subnets) and exposes it as the `X-Client-Zone` response header, verifiable with `curl -I`. Nothing is restricted based on it yet.

#### nginx **Start**

```bash
docker compose up -d
```

Then, from a device whose DNS resolves `*.home.arpa` to the home server (see [AdGuard Start](#adguard-start)): `https://adguard.home.arpa`, `https://jellyfin.home.arpa`, `https://syncthing.home.arpa`.

---

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
