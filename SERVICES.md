# Home server services

This document details the deployment of dockerized self-hosted services running on your local Home Server.

## Prerequisites

### Docker & Docker compose installed

Follow the [official documentation](https://docs.docker.com/engine/install/) to install it.

## Services

The services are defined in `services/docker-compose.yml`. Copy the services you need to your main `docker-compose.yml` or run them directly from that directory.

Start the services:

```bash
docker compose up -d
```

Check the status:

```bash
docker compose ps
```

---

### [Pi-hole](https://hub.docker.com/r/pihole/pihole)

A network-wide ad blocking software acting as a DNS sinkhole.

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

By default, the Syncthing web interface is accessible without any credentials, so is highly recomended to set a username and password.

Open the web UI at `http://<SERVER_IP>:8384` and go to: `Actions > Settings > GUI > Set user/password`. Here add your usser name and password. It's also recommended to activate the option `Use HTTPS for GUI`.

#### Syncthing **Start**

Once it's runing, you can start syncing files by following these steps:

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

> Adjust the `/path/to/media` volume in `docker-compose.yml` to point at your actual media library.
