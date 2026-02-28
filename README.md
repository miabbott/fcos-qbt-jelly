# fcos-qbt-jelly

Fedora CoreOS Butane configuration for a small Intel-based system running
qBittorrent and Jellyfin behind NordVPN.

## Services

| Service | Port | Notes |
|---|---|---|
| Jellyfin | 8096 (HTTP), 8920 (HTTPS) | Media server; uncomment `AddDevice` in `.bu` for Intel Quick Sync |
| qBittorrent | 8080 (web UI), 6881 (torrenting) | Initial password printed to container logs on first boot |
| NordVPN | — | Installed as a systemd sysext; run `nordvpn login` after first boot |

## Requirements

- `podman`
- `python3`
- [`just`](https://github.com/casey/just)
- `firewall-cmd`

## Usage

```
just                       # transpile + validate
just serve                 # transpile + validate + serve .ign in background
just stop                  # stop the background server and close the firewall port
just write-iso /dev/sdX    # download latest FCOS live ISO and write to USB key
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

## Post-Install

```bash
nordvpn login
nordvpn connect
```

## License

MIT
