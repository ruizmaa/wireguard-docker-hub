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

Copy `.env.example` (repo root) to `.env` in this directory and set `PUID`/`PGID`/`TZ` plus your real Syncthing (`SYNCTHING_MOUNT_1`, `SYNCTHING_MOUNT_2`, etc.) data mounts, each a full `host_path:container_path`.

The host ports (`NGINX_HTTP_PORT`, `NGINX_HTTPS_PORT`, `ADGUARD_WEB_PORT`, `ADGUARD_DNS_PORT`, `ADGUARD_SETUP_PORT`, `HOMEPAGE_WEB_PORT`, `JELLYFIN_WEB_PORT`, `JELLYFIN_DISCOVERY_PORT`, `SYNCTHING_WEB_PORT`, `SYNCTHING_SYNC_PORT`, `SYNCTHING_DISCOVERY_PORT`, `DOCKGE_WEB_PORT`, `GLANCES_WEB_PORT`, `QBITTORRENT_WEB_PORT`, `QBITTORRENT_TORRENT_PORT`, `PROWLARR_WEB_PORT`, `LIDARR_WEB_PORT`, `RADARR_WEB_PORT`, `SONARR_WEB_PORT`) are optional. Leave them out to use the defaults shown in `.env.example`, or set them if you need these services on different ports.

`LAN_SUBNET` and `VPN_SUBNET` are required for [nginx](#nginx-reverse-proxy), as are `TRUENAS_IP` and the `PVE1_IP`/`PVE2_IP`/`PBS_IP` of the [external devices it proxies](#proxying-external-devices-proxmox-ve-and-pbs). `HOMEPAGE_ALLOWED_HOSTS` is required for [Homepage](#homepage). `docker compose up` refuses to start the whole stack if any of these are missing. `GLANCES_PASSWORD` is also required, see [Glances](#glances), but it only fails that one container instead of the whole stack.

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

- Web interface: `http://<SERVER_IP>:3001`, also proxied at `https://homepage.home.arpa` if [nginx](#nginx-reverse-proxy) is in use
- Config directory (bind mount): `services/homepage/` -> `/app/config`

> [!IMPORTANT]
> Set `HOMEPAGE_ALLOWED_HOSTS` in `.env`: every host[:port] you access Homepage from, comma-separated (e.g. `192.168.1.X:3001` for its LAN IP, `10.13.13.X:3001` for its WireGuard tunnel IP if you also reach it over the VPN, plus `homepage.home.arpa` if [nginx](#nginx-reverse-proxy) is in use). This is a security allowlist: whichever address you type in your browser is sent as the `Host` header, and Homepage only trusts `localhost:3000`/`127.0.0.1:3000` by default (its container-internal port, not the published `HOMEPAGE_WEB_PORT`). So every widget (resources, service status, search suggestions...) would otherwise fail with a "Host validation failed" error. `docker compose up` refuses to start the whole stack if it's missing.
>
> The services cards link to their `*.home.arpa` addresses (see [nginx](#nginx-reverse-proxy)), one card per service since [AdGuard's split-horizon DNS](#adguard-configuration) already resolves them to the right IP depending on where you're connecting from. This only works from a device that's actually using AdGuard as its DNS server (see the [note below](#adguard-home)), otherwise those links won't resolve.

All customization is done through YAML files inside `services/homepage/`, which are tracked in this repository:

| File | Purpose |
|---|---|
| `services.yaml` | Define the service cards shown on the dashboard |
| `bookmarks.yaml` | Shortcut links |
| `widgets.yaml` | Top-bar info widgets (date, search, resources…) |
| `settings.yaml` | Global settings (title, theme, layout…) |

The Proxmox and PBS cards also carry a widget each, showing VMs/containers and CPU/memory for a node, and datastore usage plus failed backup tasks for PBS. They need a read-only API token per node in `.env` (`PVE1_TOKEN_ID`/`PVE1_TOKEN_SECRET` and so on), created like this:

- **Proxmox VE**: `Datacenter > Permissions > API Tokens > Add`. Untick *Privilege Separation* or give the token itself the `PVEAuditor` role on `/` under `Datacenter > Permissions`. The ID goes in `.env` in full, e.g. `root@pam!homepage`.
- **PBS**: `Configuration > Access Control > API Token > Add`, then assign the `Audit` role on `/` to both the user and the token (PBS treats them separately). The ID is e.g. `root@pbs!homepage`.

Each node keeps its own token: they're standalone, so they don't share a user database. Homepage fires the API call whether or not the pair is filled in, so an unset token shows that card with an authentication error rather than silently without stats. If you'd rather not set one up, delete that card's `widget:` block from `services/homepage/services.yaml`. Unlike the card links, these widgets talk to each node's API directly by IP (`PVE1_IP` and friends, ports 8006/8007), not through nginx, because the Homepage container resolves names through Docker's DNS, which doesn't know AdGuard's `*.home.arpa` rewrites.

Edit those files, commit the changes, and restart the container to apply them:

```bash
docker compose restart homepage
```

#### Homepage **Start**

Open the web UI at `http://<SERVER_IP>:3001` (or `https://homepage.home.arpa` if [nginx](#nginx-reverse-proxy) is in use). The default page is ready to use out of the box. Edit the YAML files in `services/homepage/` to add your services, bookmarks and widgets, then commit the changes.

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
> If [nginx](#nginx-reverse-proxy) is in use, it also sets up split-horizon DNS for `adguard.home.arpa`/`homepage.home.arpa`/`jellyfin.home.arpa`/`qbittorrent.home.arpa`/`prowlarr.home.arpa`/`lidarr.home.arpa`/`radarr.home.arpa`/`sonarr.home.arpa`/`syncthing.home.arpa`/`dockge.home.arpa`/`glances.home.arpa`/`truenas.home.arpa`/`pve1.home.arpa`/`pve2.home.arpa`/`pbs.home.arpa`, showing what it's about to change before asking for confirmation:
>
> - LAN clients resolve them to this host's LAN IP, found via a route lookup against `LAN_SUBNET` (overridable with `ADGUARD_LAN_IP`, CI sets this).
> - VPN (WireGuard) clients resolve them to this host's own tunnel IP instead, read from its `wg0` interface (overridable with `ADGUARD_VPN_IP`, CI sets this).
>
> No WireGuard changes needed: nginx already listens on `wg0`, so this works without widening the VPS peer's `AllowedIPs` (see [README](README.md)).
>
> Everything except the password comes from the tracked `services/adguard/AdGuardHome.yaml.template` (see [Tracking your config](#tracking-your-config) below).
>
> The split-horizon rules above only resolve names once a client is already using AdGuard as its DNS server. For your roaming (phone/laptop) VPN clients, set `PEERDNS` in the VPS's `.env` (see `.env.example`), then regenerate/re-import that peer's config so it picks up the change.

#### AdGuard **Start**

Log in at `http://<SERVER_IP>:8080` with the username/password you gave the script above, then configure:

- **Upstream DNS Servers** (`Settings > DNS settings`): your preferred resolver (e.g. Cloudflare, Quad9).
- **DNS blocklists** (`Filters > DNS blocklists`): AdGuard ships with one enabled by default, add more from its list of curated sources if you want.

If you're using [nginx](#nginx-reverse-proxy), `generate-adguard-config.sh` already set up `adguard.home.arpa`/`homepage.home.arpa`/`jellyfin.home.arpa`/`qbittorrent.home.arpa`/`prowlarr.home.arpa`/`lidarr.home.arpa`/`radarr.home.arpa`/`sonarr.home.arpa`/`syncthing.home.arpa`/`dockge.home.arpa`/`glances.home.arpa`/`truenas.home.arpa`/`pve1.home.arpa`/`pve2.home.arpa`/`pbs.home.arpa` for you as *Custom filtering rules* (`Filters > Custom filtering rules`), split by LAN/VPN, nothing to do manually.

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
  - `jellyfin_config` -> `/config`
  - `jellyfin_cache`  -> `/cache`
- Media path (read-only): `${LOCAL_MOUNT_MEDIA_PATH}/movies` -> `/data/movies`, `${LOCAL_MOUNT_MEDIA_PATH}/series` -> `/data/series`, `${LOCAL_MOUNT_MEDIA_PATH}/music` -> `/data/music`, same source as [lidarr](#lidarr)/[radarr](#radarr)/[sonarr](#sonarr)/[qbittorrent](#qbittorrent)

> [!IMPORTANT]
> Before the first `docker compose up`, run:
>
> ```bash
> ./services/setup-nfs.sh
> ```
>
> This script mounts your TrueNAS NFS share (`TRUENAS_IP`/`TRUENAS_MEDIA_PATH`) at `LOCAL_MOUNT_MEDIA_PATH` and persists it in `/etc/fstab` and automatically verifies that the media directories required by the `docker-compose` stack exist on your TrueNAS share. If any are missing, it will safely halt and provide you with the exact `mkdir` command needed to create them. Without running this setup, Docker would create an empty local directory and your services would start against an empty library.

> [!IMPORTANT]
> `lidarr`/`radarr`/`sonarr`/`qbittorrent` run as `PUID=1000`/`PGID=1000`, but existing dirs won't have their permissions checked here, the directories above only get checked for existence. If TrueNAS owns them as a different user, writes will fail with `Permission denied` (qBittorrent downloads erroring out, Lidarr/Radarr/Sonarr logging `Folder '...' is not writable by user 'abc'`), even though the mount itself succeeds. Fix it on the TrueNAS side, either:
>
> - `chown -R 1000:1000` on the exported directories, or
> - set `Mapall User`/`Mapall Group` to a user that owns them, on the NFS share itself (`Sharing > NFS`). This remaps every NFS client's UID to that user, so it also affects any other machine mounting the same share.

> [!IMPORTANT]
> The compose file passes through `/dev/dri` for Intel QuickSync hardware transcoding. On a host without an Intel iGPU (AMD, ARM, a VM without GPU passthrough...), that device doesn't exist and the container fails to start. Comment out the `devices:` block under `jellyfin` in `services/docker-compose.yml` if that's your case; Jellyfin falls back to software transcoding.
>
> If you do have an Intel iGPU, run this once before the first `docker compose up` so the container actually has drivers to use it:
>
> ```bash
> ./services/setup-jellyfin-hwaccel.sh
> ```
>
> Installs `intel-media-va-driver-non-free` and its firmware, then verifies `vainfo` reports a working VAAPI device. The container picks up the device's host group on its own (linuxserver's `ATTACHED_DEVICES_PERMS`), no extra config needed. Enable it afterwards in Jellyfin: `Dashboard > Playback > Transcoding > Hardware acceleration > Intel QuickSync (QSV)`.

> [!NOTE]
> **Running the home server as a Proxmox VM?** `/dev/dri` won't exist in a fresh VM on its own, the iGPU has to be passed through from the hypervisor first:
>
> 1. On the **Proxmox host** (not the VM): enable IOMMU by adding `intel_iommu=on iommu=pt` to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then `update-grub` and reboot. Confirm VT-d is enabled in the BIOS first with `ls /sys/firmware/acpi/tables/ | grep -i dmar`, should print `DMAR`, if it doesn't, enable VT-d in the BIOS setup and try again.
> 2. Still on the host: find the iGPU's PCI ID (`lspci -nn | grep -i vga`, e.g. `8086:46d1`) and reserve it for passthrough instead of letting the host's own `i915` grab it:
>    ```bash
>    printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' >> /etc/modules
>    echo 'options vfio-pci ids=<vendor:device>' > /etc/modprobe.d/vfio.conf
>    echo 'blacklist i915' > /etc/modprobe.d/blacklist-igpu.conf
>    update-initramfs -u -k all
>    ```
>    Reboot, then confirm with `lspci -k -s <pci-address>` that `Kernel driver in use` is now `vfio-pci`.
> 3. Shut the VM down, attach the device (`qm set <vmid> -hostpci0 <pci-address>,pcie=0,x-vga=0`, or `Hardware > Add > PCI Device` in the UI, leaving "Primary GPU" unchecked), and start it back up.
> 4. Inside the VM, run `./services/setup-jellyfin-hwaccel.sh` above as usual.

#### Jellyfin **Start**

Open the web UI at `http://<SERVER_IP>:8096` and run through the setup wizard, or configure these manually afterwards under `Dashboard`:

- **Users** (`Dashboard > Users > +`): set username/password, then on that user tune `Access` (which libraries they can see), `Playback` (allow/restrict direct play vs transcoding) and uncheck the admin permissions for non-admin accounts.
- **Libraries** (`Dashboard > Libraries > Add Media Library`): one library with content type `Movies` and folder `/data/movies`, another with content type `Shows` and folder `/data/series`, another with content type `Music` and folder `/data/music` and so on, matching the mounts above. Set your preferred metadata language/country and enable the providers you want (TheMovieDB, TheTVDB, OpenSubtitles...), then let the initial library scan finish.
- **Hardware acceleration** (after running `setup-jellyfin-hwaccel.sh` above): Go to `Dashboard > Playback > Transcoding` and set `Hardware acceleration` to `Intel QuickSync (QSV)` and `QSV device` to `/dev/dri/renderD128`. Enable hardware decoding for the codecs your library uses (H264, HEVC, HEVC 10bit, VP9, VP9 10bit, MPEG2, VC1, AV1). If `dmesg | grep -i huc` shows `HuC: authenticated for all workloads`, also enable the low-power encoders for H.264/HEVC. Leave AV1 encoding off unless your iGPU actually has a hardware AV1 encoder, otherwise enabling it just pushes the encode onto the CPU instead. Enable VPP tone mapping for HDR->SDR. Verify afterwards that compatible content plays back as `Direct Play` (no transcoding) in the active-sessions panel.

### [qBittorrent](https://hub.docker.com/r/linuxserver/qbittorrent)

A BitTorrent client, used by [Lidarr](#lidarr)/[Radarr](#radarr)/[Sonarr](#sonarr) as their download client.

#### qBittorrent **Configuration**

- Web interface: `http://<SERVER_IP>:8081`
- Persistent volume: `qbittorrent_config` -> `/config`
- Media path: `${LOCAL_MOUNT_MEDIA_PATH}` -> `/media`, same source [Lidarr](#lidarr)/[Radarr](#radarr)/[Sonarr](#sonarr)/[Jellyfin](#jellyfin) read from

> [!IMPORTANT]
> On first start, the linuxserver image generates a random temporary admin password. Find it with `docker compose logs qbittorrent | grep password`, log in, then change it under `Tools > Options > WebUI`.

#### qBittorrent **Start**

Open the web UI at `http://<SERVER_IP>:8081`, log in with the temporary password above, and change the credentials under `Tools > Options > WebUI`. [Lidarr](#lidarr)/[Radarr](#radarr)/[Sonarr](#sonarr) reach qBittorrent over the Docker network (not localhost), so `WebUI > Authentication > Bypass authentication for clients on localhost` doesn't apply to them, enter these same credentials when adding qBittorrent as their download client instead. The default save path (`Tools > Options > Downloads`) already points at `/media/downloads` via `qBittorrent.conf.defaults`, matching the path [Lidarr](#lidarr)/[Radarr](#radarr)/[Sonarr](#sonarr) see under their own `/media` mount, so Completed Download Handling can import automatically.

### [Prowlarr](https://hub.docker.com/r/linuxserver/prowlarr)

An indexer manager: configure your indexers once here, then [Lidarr](#lidarr)/[Radarr](#radarr)/[Sonarr](#sonarr) pull them automatically instead of being set up per-app.

#### Prowlarr **Configuration**

- Web interface: `http://<SERVER_IP>:9696`
- Persistent volume: `prowlarr_config` -> `/config`

#### Prowlarr **Start**

Open the web UI at `http://<SERVER_IP>:9696` and add your indexers under `Indexers`. Then add [Lidarr](#lidarr), [Radarr](#radarr) and [Sonarr](#sonarr) under `Settings > Apps` (Prowlarr Server: `http://prowlarr:9696`, app URLs `http://lidarr:8686`/`http://radarr:7878`/`http://sonarr:8989`) so it keeps their indexer lists in sync.

### [Lidarr](https://hub.docker.com/r/linuxserver/lidarr)

A music collection manager: tracks your wanted artists and albums, searches [Prowlarr](#prowlarr)'s indexers for releases, and sends them to [qBittorrent](#qbittorrent).

#### Lidarr **Configuration**

- Web interface: `http://<SERVER_IP>:8686`
- Persistent volume: `lidarr_config` -> `/config`
- Media path: `${LOCAL_MOUNT_MEDIA_PATH}` -> `/media`, same source [Jellyfin](#jellyfin) reads from

#### Lidarr **Start**

Open the web UI at `http://<SERVER_IP>:8686`. Add qBittorrent as a download client (`Settings > Download Clients`, host `qbittorrent`, port `8080`, plus the WebUI credentials from [qBittorrent's setup](#qbittorrent-start)) and set your root media folder to `/media/music` (not just `/media`, [Jellyfin](#jellyfin) only mounts the `movies`/`series`/`music` subfolders, so imports need to land there to show up). Indexers are populated automatically once [Prowlarr](#prowlarr) is configured to sync with it.

### [Radarr](https://hub.docker.com/r/linuxserver/radarr)

A movie collection manager: tracks a wishlist, searches [Prowlarr](#prowlarr)'s indexers for releases, and sends them to [qBittorrent](#qbittorrent).

#### Radarr **Configuration**

- Web interface: `http://<SERVER_IP>:7878`
- Persistent volume: `radarr_config` -> `/config`
- Media path: `${LOCAL_MOUNT_MEDIA_PATH}` -> `/media`, same source [Jellyfin](#jellyfin) reads from

#### Radarr **Start**

Open the web UI at `http://<SERVER_IP>:7878`. Add qBittorrent as a download client (`Settings > Download Clients`, host `qbittorrent`, port `8080`, plus the WebUI credentials from [qBittorrent's setup](#qbittorrent-start)) and set your root media folder to `/media/movies` (not just `/media`, [Jellyfin](#jellyfin) only mounts the `movies`/`series`/`music` subfolders, so imports need to land there to show up). Indexers are populated automatically once [Prowlarr](#prowlarr) is configured to sync with it.

### [Sonarr](https://hub.docker.com/r/linuxserver/sonarr)

A TV show collection manager: tracks your series and new episodes as they air, searches [Prowlarr](#prowlarr)'s indexers for releases, and sends them to [qBittorrent](#qbittorrent).

#### Sonarr **Configuration**

- Web interface: `http://<SERVER_IP>:8989`
- Persistent volume: `sonarr_config` -> `/config`
- Media path: `${LOCAL_MOUNT_MEDIA_PATH}` -> `/media`, same source [Jellyfin](#jellyfin) reads from

#### Sonarr **Start**

Open the web UI at `http://<SERVER_IP>:8989`. Add qBittorrent as a download client (`Settings > Download Clients`, host `qbittorrent`, port `8080`, plus the WebUI credentials from [qBittorrent's setup](#qbittorrent-start)) and set your root media folder to `/media/series` (not just `/media`, [Jellyfin](#jellyfin) only mounts the `movies`/`series`/`music` subfolders, so imports need to land there to show up). Indexers are populated automatically once [Prowlarr](#prowlarr) is configured to sync with it.

### [Dockge](https://github.com/louislam/dockge)

A lightweight UI for managing `docker compose` stacks: start/stop/restart, live logs, and an in-browser editor for their compose files.

#### Dockge **Configuration**

- Web interface: `http://<SERVER_IP>:5001`, also proxied at `https://dockge.home.arpa` if [nginx](#nginx-reverse-proxy) is in use
- Stacks directory (bind mount, both sides must be the same path): `${DOCKGE_STACKS_DIR:-/opt/stacks}` on the host and same path in the container

> [!WARNING]
> Dockge mounts the host's Docker socket (`/var/run/docker.sock`) to manage containers, which is equivalent to root access on the host: anything with access to Dockge can start a container with a host bind mount and read/write any file the daemon can reach. Treat its web UI as sensitive as a root shell.
>
> This image always runs as root regardless of any `PUID`/`PGID` setting ([louislam/dockge#956](https://github.com/louislam/dockge/issues/956)), so any stack file it writes under `DOCKGE_STACKS_DIR` will be owned by `root:root` on the host. Editing those files over SSH as a normal user will need `sudo`.

#### Dockge **Start**

Open the web UI at `http://<SERVER_IP>:5001` (or `https://dockge.home.arpa` if [nginx](#nginx-reverse-proxy) is in use) and set a username/password on first visit. Existing stacks under `DOCKGE_STACKS_DIR` are picked up automatically; create new ones from the UI.

Its username, password hash, and UI settings all live inside the `dockge_data` volume as a SQLite database, not a plain file. You set the username/password once, interactively, the first time you open the web UI. If that volume is ever removed, you'll go through this setup again.

### [Glances](https://github.com/nicolargo/glances)

A system monitor: CPU load, RAM, disk and network usage of the machine it runs on. Also feeds the CPU/RAM numbers shown at the top of [Homepage](#homepage) (see `services/homepage/widgets.yaml`), which can't get real machine-wide numbers on its own (see below).

#### Glances **Configuration**

- Web interface: `http://<SERVER_IP>:61208`, also proxied at `https://glances.home.arpa` if [nginx](#nginx-reverse-proxy) is in use
- Unlike most system monitors run in Docker, this container has no `pid: host` and doesn't mount `/var/run/docker.sock`: CPU/RAM/disk/network are already visible from inside an unprivileged container (Linux doesn't isolate `/proc`/`/sys` by default), and those two extras would only add the host's full process list and per-container stats, neither of which this deployment uses.
- CPU temperature isn't available: this only works with real hardware sensors, and a VM (which is what this project is designed to run on) doesn't have any to expose.

> [!IMPORTANT]
> Set `GLANCES_USERNAME` (defaults to `glances` if unset) and `GLANCES_PASSWORD` in `.env`, then before the first `docker compose up`, run:
>
> ```bash
> ./services/generate-glances-config.sh
> ```
>
> Reads both straight from `.env` and writes `services/glances/<username>.pwd`, hashed the same way Glances' own `--password` flag would. Without it, the container crash-loops instead of starting: it tries to prompt for a password interactively, which fails non-interactively in Docker. [Homepage](#homepage)'s dashboard widget reads the same `.env` values to authenticate against Glances, so this also recreates Homepage to pick them up. Re-run with `--force` after changing either value in `.env`.

#### Glances **Start**

Open the web UI at `http://<SERVER_IP>:61208` (or `https://glances.home.arpa` if [nginx](#nginx-reverse-proxy) is in use) and log in with the username/password you set above.

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
> Before the first `docker compose up`, generate a wildcard TLS cert for all `*.home.arpa` subdomains, signed by a local CA (this installs [mkcert](https://github.com/FiloSottile/mkcert#installation) via `apt-get` if it's missing. Install `libnss3-tools` yourself first if you also want the CA trusted by Firefox on the home server itself):
>
> ```bash
> ./services/generate-nginx-certs.sh
> ```
>
> This creates a root CA once at `services/nginx/ca/` and a cert signed by it. Import `services/nginx/ca/rootCA.pem` as a trusted authority on each of your devices once. After that, re-running with `--force` (e.g. once the cert is close to expiring) renews the cert without any browser warnings or re-importing, since it's signed by the same CA your devices already trust. If nginx is already running, this also restarts it so it picks up the new cert.
>
> Also set `LAN_SUBNET` and `VPN_SUBNET` in `.env` (see `.env.example`). Your LAN's CIDR, and the VPS's `INTERNAL_SUBNET` as a CIDR, these decide the `lan`/`vpn`/`external` split described below.

Finally, so `<service>.home.arpa` actually resolves: run (or re-run) [`generate-adguard-config.sh`](#adguard-configuration) after this — it sets up split-horizon DNS automatically (LAN clients get this host's LAN IP, VPN clients get its WireGuard tunnel IP).

#### Proxying external devices (Proxmox VE and PBS)

Not everything behind nginx is a container in this compose file. TrueNAS, the Proxmox VE nodes and Proxmox Backup
Server are separate boxes on the LAN, so their templates point at an IP from `.env` (`TRUENAS_IP`, `PVE1_IP`,
`PVE2_IP`, `PBS_IP`) instead of a container name.

Proxmox VE and PBS differ from every other backend in one more way: they only speak HTTPS (on 8006 and 8007), with
their own self-signed certificate. So each template declares the scheme right next to its backend:

```nginx
set $backend ${PVE1_IP}:8006;
set $backend_scheme https;
```

`proxy_params.conf` proxies to `$backend_scheme://$backend` and doesn't verify the backend's certificate chain.
Every other template says `http` today; switching one to `https` is how a service moves to TLS on that inner hop.

> [!NOTE]
> A template that forgets `set $backend_scheme` still passes `nginx -t`, then answers `500` at request time with
> `invalid URL prefix` in the log. CI checks every template for it.

To add or drop a node, copy `conf.d/pve1.conf.template` to `conf.d/<name>.conf.template` (or delete it) and keep
its `<NAME>_IP` in sync in three places: `.env`, the `nginx` service's `environment` and its `NGINX_ENVSUBST_FILTER`
in `services/docker-compose.yml`. Only nginx's copy carries the `:?` that makes it required, so those three stay
together; the `homepage` service reads the same variable without one. A dropped node also leaves its card behind
in `services/homepage/services.yaml`, pointing at an empty address -- delete that too. Its `<name>.home.arpa` DNS
rewrite is picked up automatically the next time you run [`generate-adguard-config.sh`](#adguard-configuration),
which reads the `conf.d/` templates.

#### LAN vs. WireGuard zone

nginx computes a `$zone` per request from the client's source IP (`lan`, `vpn`, or `external` for anything outside both subnets) and exposes it as the `X-Client-Zone` response header, verifiable with `curl -I`. Nothing is restricted based on it yet.

#### nginx **Start**

```bash
docker compose up -d
```

Then, from a device whose DNS resolves `*.home.arpa` to the home server (see [AdGuard Start](#adguard-start)): `https://adguard.home.arpa`, `https://homepage.home.arpa`, `https://jellyfin.home.arpa`, `https://qbittorrent.home.arpa`, `https://prowlarr.home.arpa`, `https://lidarr.home.arpa`, `https://radarr.home.arpa`, `https://sonarr.home.arpa`, `https://syncthing.home.arpa`, `https://dockge.home.arpa`, `https://glances.home.arpa`, `https://truenas.home.arpa`, `https://pve1.home.arpa`, `https://pve2.home.arpa`, `https://pbs.home.arpa`.

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

## Test environment

Before merging a branch that touches `services/`, you can try it out on the same home server without touching production: a second, isolated copy of this stack (project name `test-env`, ports and scratch data completely separate from production) that only ever exists while you're actively testing.

- **One-time setup** (only needed once, ever): `sudo mkdir -p /opt/test-env-data && sudo chown <runner-user>:<runner-user> /opt/test-env-data` on the home server, replacing `<runner-user>` with whichever user runs the self-hosted GitHub Actions runner. This mirrors how [Dockge's `DOCKGE_STACKS_DIR`](#dockge) already needs a real host path.
- **To test a branch:** in GitHub, go to Actions -> "Test Services (on-demand)" -> Run workflow, pick your branch, leave `action` as `deploy`. It tears down and wipes any previous test run first, so it's always a clean start regardless of what branch was tested last.
- **When you're done:** run the same workflow again with `action` set to `teardown`, otherwise the test stack keeps running (and using host resources) until the next `deploy` wipes it.

This only checks that the containers themselves start correctly with your changes (images, compose syntax, env vars, healthchecks). It does **not** exercise real nginx reverse-proxy routing, AdGuard's split-horizon DNS, or the WireGuard tunnel, the test stack's `LAN_SUBNET`/`VPN_SUBNET`/`TRUENAS_IP` are dummy values (see `services/.env.test.example`), not your real network.
