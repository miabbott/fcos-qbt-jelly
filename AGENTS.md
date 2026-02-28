# Agent Guidelines

This repository contains a Fedora CoreOS Butane configuration that provisions
a system as a BitTorrent client and Jellyfin media server connected via NordVPN.

## Repository Structure

- `fcos-qbt-jelly.bu` — Butane YAML source (edit this, never the `.ign` file)
- `fcos-qbt-jelly.ign` — generated Ignition JSON (do not edit; regenerate via `just`)
- `Justfile` — automation for transpile, validate, and serve workflows

## What This Config Provisions

- **Jellyfin** media server via Podman Quadlet (`/etc/containers/systemd/jellyfin.container`)
  - Web UI on port 8096; HTTPS on 8920
  - Media volumes: `/var/mnt/media/{movies,tv,music}` (read-only mounts into container)
  - Intel Quick Sync transcoding available — uncomment `AddDevice=/dev/dri/renderD128`
- **qBittorrent** torrent client via Podman Quadlet (`/etc/containers/systemd/qbittorrent.container`)
  - Web UI on port 8080; torrenting on port 6881 TCP/UDP
  - Downloads land in `/var/mnt/downloads`
  - Initial admin password is printed to container logs on first boot
- **NordVPN** installed as a systemd sysext via `extensions.fcos.fr`, not rpm-ostree
  - First-boot service: `nordvpn-sysext-install.service`
  - Weekly auto-update: `nordvpn-sysext-update.timer`
  - After first boot, authenticate with `nordvpn login` then `nordvpn connect`
- **Zincati** OS update reboots restricted to Saturday/Sunday 02:00–03:30
- **podman-auto-update.timer** enabled for daily container image refresh

## Key Constraints

- The Butane spec version is `1.7.0` (Ignition spec `3.6.0`). Do not downgrade.
- All persistent data must live under `/var` — it is the only writable tree on CoreOS.
  The `/etc` tree is writable but is for configuration only, not user data.
- Volume mounts in Quadlet units must use the `:Z` SELinux relabeling suffix or
  containers will receive permission denied errors at runtime.
- `fcos-qbt-jelly.ign` is a generated file. Never commit edits to it directly;
  always edit the `.bu` source and regenerate.

## Workflow

Requires: `podman`, `python3`, `just`, `firewall-cmd`

```
just          # transpile + validate (default)
just serve    # transpile + validate + serve .ign over HTTP on port 8000
just clean    # remove the generated .ign file
```

Transpilation and validation use official containers (`quay.io/coreos/butane:release`
and `quay.io/coreos/ignition-validate:release`) so no local Butane install is needed.

The `serve` target manages the firewalld port automatically: it opens port 8000/tcp
if not already open, prints the `coreos-installer` command to run on the target, and
closes the port again on exit (Ctrl-C).

## Installing to the Target System

Boot the target into the stock Fedora CoreOS live ISO, then at the live shell:

```bash
lsblk   # identify the target disk

sudo coreos-installer install /dev/sdX \
  --ignition-url http://<dev-machine-ip>:8000/fcos-qbt-jelly.ign \
  --insecure-ignition

sudo reboot
```

The `--insecure-ignition` flag is required when serving over plain HTTP. This is
acceptable for local development; do not use plain HTTP in production.

## Commit Guidelines

Follow the project-level commit conventions in `CLAUDE.md` (located at the workspace
root). All commits must be signed-off (`git commit -s`) and include the attribution
trailer `Assisted-by: Claude Code (<model>)`.
