# fcos-qbt-jelly

Fedora CoreOS Butane configuration for a small Intel-based system running
qBittorrent and Jellyfin behind NordVPN.

## Services

| Service | Port | Notes |
|---|---|---|
| Jellyfin | 8096 (HTTP), 8920 (HTTPS) | Media server; uncomment `AddDevice` in `.bu` for Intel Quick Sync |
| qBittorrent | 8080 (web UI), 6881 (torrenting) | Initial password printed to container logs on first boot; torrent traffic bound to the `nordlynx` interface and port 6881 is allowlisted through the NordVPN kill-switch |
| Caddy | 80 | Reverse proxy routing `jellyfin.home` → `:8096` and `qbt.home` → `:8080`. HTTP only — no TLS on the LAN |
| NordVPN | — | Installed as a systemd sysext; token-based login and auto-connect to Switzerland on every boot. A 15-minute watchdog timer reconnects the tunnel if `nordvpn status` is not `Connected`. A weekly timer updates the sysext from `extensions.fcos.fr`. |

### Accessing the services by name

Caddy routes on the `Host` header, so `jellyfin.home` and `qbt.home` must resolve
to the host's LAN IP on any client that wants to use the friendly names. Either
add entries to `/etc/hosts` on each client, or add A records for both names on
your LAN DNS resolver pointing at the host.

IPv6 is disabled on the host's ethernet link via NetworkManager to keep all
traffic on IPv4 and avoid dual-stack quirks with the NordLynx tunnel.

## Requirements

- `podman`
- `python3`
- [`just`](https://github.com/casey/just)
- `firewall-cmd`
- `secrets/nordvpn-token` — NordVPN access token (gitignored; see below)

## Usage

```
just                       # transpile + validate
just serve                 # transpile + validate + serve .ign in background
just stop                  # stop the background server and close the firewall port
just write-iso /dev/sdX    # download latest FCOS live ISO and write to USB key
just vm-install            # iterate on ignition config using a local libvirt VM
just vm-clean              # remove cached QCOW2 base image
just clean                 # remove generated .ign file and server pid file
```

## Installing to the Target

**Step 1 — Write the live ISO to a USB key:**

```bash
just write-iso /dev/sdX   # replace /dev/sdX with your USB device
```

This downloads the latest stable Fedora CoreOS live ISO and writes it directly to the
USB key. Alternatively, download manually from the
[Fedora CoreOS download page](https://fedoraproject.org/coreos/download/) and write
with a graphical tool such as [Fedora Media Writer](https://flathub.org/apps/org.fedoraproject.MediaWriter).

**Step 2 — Boot the target** from the USB key. Most systems require pressing F11, F12,
or Del at power-on to select a boot device. The live environment will start automatically
and drop you into a shell.

**Step 3 — Start serving the Ignition config** from your dev machine:

```bash
just serve
```

**Step 4 — Install** from the live shell:

```bash
lsblk   # identify the target disk

sudo coreos-installer install /dev/sdX \
  --ignition-url http://<dev-machine-ip>:8000/fcos-qbt-jelly.ign \
  --insecure-ignition

sudo reboot
```

`just serve` prints the exact `coreos-installer` command with your local IP filled in.
Run `just stop` on your dev machine once the installation is complete.

## Secrets

Before transpiling, create the `secrets/` directory and populate it:

```bash
mkdir -p secrets
echo -n 'your-token-here' > secrets/nordvpn-token
```

Generate a token at account.nordvpn.com → Security → Access Tokens. Set it
to never expire. The token is embedded into the Ignition config at transpile
time and is never committed to git.

## Post-Install

NordVPN logs in and connects automatically on every boot via the embedded
token. No manual intervention is required after first boot. Once the host is
up, point a browser at `http://jellyfin.home/` or `http://qbt.home/` (after
configuring DNS or `/etc/hosts` as described above) to reach the services
through Caddy, or hit `http://<host-ip>:8096` and `http://<host-ip>:8080`
directly.

## License

MIT
