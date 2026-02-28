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
just serve    # transpile + validate + serve .ign over HTTP (manages firewalld automatically)
just clean    # remove generated .ign file
```

## Installing to the Target

Boot the target into the [Fedora CoreOS live ISO](https://fedoraproject.org/coreos/download/),
then from the live shell:

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
