# WireGuard Client Setup Guide

This guide explains how to connect clients to your WireGuard Hub VPS.

Configuration files for clients are generated automatically on the VPS inside:

```bash
./config/peer<ID>/
```

## How to get your generated client configuration

On the VPS:

```bash
./wireguard.sh conf-file <ID>
```

This will print something like:

```bash
./config/peer1/peer1.conf
```

### How to download the configuration file

You can use `scp` to copy the file to your client machine:

```bash
scp <USER>@<VPS_PUBLIC_IP>:<PATH>/peer1.conf .
```

>Replace `<USER>`, `<VPS_PUBLIC_IP>`, and `<PATH>` with your real values
>
>Example: `scp ubuntu@1.2.3.4:~/wireguard/config/peer1/peer1.conf .`

## Linux client (Debian/Ubuntu + Systemd)

### 1. Install WireGuard

```bash
sudo apt update
sudo apt install wireguard
```

### 2. Place the configuration file

#### A. Move the downloaded file into place

You can download the file from the VPS and move it to WireGuard's configuration directory ((please check [How to download the configuration file](#how-to-download-the-configuration-file)):

```bash
sudo mv peer1.conf /etc/wireguard/wg0.conf
sudo chmod 600 /etc/wireguard/wg0.conf
```

> [!IMPORTANT]
>The file must be named `wg0.conf` and must have permission `600`.

#### B. Create the file manually

If you prefer to paste the configuration manually ((please check [How to get your generated client configuration](#how-to-get-your-generated-client-configuration)):

```bash
sudo touch /etc/wireguard/wg0.conf
sudo nano /etc/wireguard/wg0.conf
sudo chmod 600 /etc/wireguard/wg0.conf
```

> [!IMPORTANT]
>The file must be named `wg0.conf` and must have permission `600`.

### 3. Enable and start the tunnel

WireGuard configurations might include a `DNS=` line.

On Debian/Ubuntu, this requires the resolvconf package to be installed, without it, wg-quick may fail to bring the interface up.

```bash
sudo apt install resolvconf
```

```bash
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0
```

### 4. Check status

```bash
sudo wg
```

You should see out put containing:

* Your client’s private/public keys
* The VPS public key
* `latest handshake: X seconds ago`
* Data transfer counters

Example:

```bash
interface: wg0
  public key: <client_pub>
  private key: (hidden)
  listening port: 51820

peer: <server_pub>
  endpoint: <vps_public_ip>:51820
  allowed ips: 0.0.0.0/0
  latest handshake: 5 seconds ago
  transfer: 30 KiB received, 28 KiB sent
```

If you see a handshake, the tunnel is working.
