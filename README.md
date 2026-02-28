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
just          # transpile + validate
just serve    # transpile + validate + serve .ign in background (manages firewalld automatically)
just stop     # stop the background server and close the firewall port
just clean    # remove generated .ign file and server pid file
```

## Installing to the Target

**Step 1 — Download the live ISO** from the [Fedora CoreOS download page](https://fedoraproject.org/coreos/download/).
Select the **Bare Metal** platform and download the **Live ISO** image.

**Step 2 — Write the ISO to a USB key** using `dd` (replace `/dev/sdX` with your USB device):

```bash
sudo dd if=fedora-coreos-<version>-live.x86_64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Alternatively, use a graphical tool such as [Fedora Media Writer](https://flathub.org/apps/org.fedoraproject.MediaWriter).

**Step 3 — Boot the target** from the USB key. Most systems require pressing F11, F12,
or Del at power-on to select a boot device. The live environment will start automatically
and drop you into a shell.

**Step 4 — Install** from the live shell:

```bash
lsblk   # identify the target disk

sudo coreos-installer install /dev/sdX \
  --ignition-url http://<dev-machine-ip>:8000/fcos-qbt-jelly.ign \
  --insecure-ignition

sudo reboot
```

`just serve` will print the exact command with your local IP filled in.

## Post-Install

```bash
nordvpn login
nordvpn connect
```

## License

MIT
