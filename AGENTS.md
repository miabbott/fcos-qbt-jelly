# Agent Guidelines

This repository contains a Fedora CoreOS Butane configuration that provisions
a system as a BitTorrent client and Jellyfin media server connected via NordVPN.

## Repository Structure

- `fcos-qbt-jelly.bu` — Butane YAML source (edit this, never the `.ign` file)
- `fcos-qbt-jelly.ign` — generated Ignition JSON (do not edit; regenerate via `just`)
- `Justfile` — automation for transpile, validate, serve, stop, write-iso, vm-install, vm-clean, and clean workflows
- `.gitignore` — excludes `fcos-qbt-jelly.ign`, `.server.pid`, and downloaded ISO files

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

- The Butane spec version is `1.6.0` (Ignition spec `3.5.0`). The `quay.io/coreos/butane:release`
  container (v0.26.0 as of early 2026) does not support `1.7.0` yet; do not upgrade until the
  container image is verified to support it.
- All persistent data must live under `/var` — it is the only writable tree on CoreOS.
  The `/etc` tree is writable but is for configuration only, not user data.
- Volume mounts in Quadlet units must use the `:Z` SELinux relabeling suffix or
  containers will receive permission denied errors at runtime.
- `fcos-qbt-jelly.ign` is a generated file. Never commit edits to it directly;
  always edit the `.bu` source and regenerate.

## Workflow

Requires: `podman`, `python3`, `just`, `firewall-cmd`

```
just                       # transpile + validate (default)
just serve                 # transpile + validate + serve .ign in background on port 8000
just stop                  # stop the background server and close the firewall port
just write-iso /dev/sdX    # download latest FCOS live ISO and write to USB key
just vm-install            # iterate on ignition config using a local libvirt VM
just vm-clean              # remove cached QCOW2 base image
just clean                 # remove the generated .ign file and .server.pid
```

Transpilation and validation use official containers (`quay.io/coreos/butane:release`
and `quay.io/coreos/ignition-validate:release`) so no local Butane install is needed.

The `serve` target starts `python3 -m http.server` in the background, opens firewalld
port 8000/tcp if not already open, and records the server PID and port state in
`.server.pid`. Run `just stop` to kill the server and restore firewall state. Server
logs go to `/tmp/fcos-httpd.log`.

The `write-iso` target uses the `coreos-installer` container to download the latest
stable Fedora CoreOS live ISO and writes it to the specified block device via `dd`.
It requires a positional argument (`just write-iso /dev/sdX`) and will prompt for
confirmation if the target appears to be an internal disk.

The `vm-install` target is used for local iteration against a libvirt VM. It requires
`virt-install` and `virsh` on the host, and the libvirt `default` network must be
active. The target downloads the FCOS QCOW2 image once and caches it as
`fcos-qbt-jelly-base.qcow2`; subsequent runs reuse the cache. Each run destroys any
existing VM of the same name, creates a throwaway overlay disk on top of the base
image, and delivers the Ignition config via the QEMU `fw_cfg` device. Use
`just vm-clean` to remove the cached base image when a fresh download is needed.

## Installing to the Target System

Write the live ISO to a USB key, boot the target from it, then at the live shell:

```bash
lsblk   # identify the target disk

sudo coreos-installer install /dev/sdX \
  --ignition-url http://<dev-machine-ip>:8000/fcos-qbt-jelly.ign \
  --insecure-ignition

sudo reboot
```

After issuing `sudo reboot`, **remove the USB key** before the system comes
back up. If the USB remains inserted and is first in the BIOS/UEFI boot order,
the system will boot back into the live environment instead of the installed OS.

`just serve` prints the exact command with the local IP filled in. The
`--insecure-ignition` flag is required when serving over plain HTTP, which is
acceptable for local development.

## Commit Guidelines

Follow the project-level commit conventions in `CLAUDE.md` (located at the workspace
root). All commits must be signed-off (`git commit -s`) and include the attribution
trailer `Assisted-by: Claude Code (<model>)`.

## Keeping Documentation in Sync

Any change to the `Justfile` must be analyzed for required updates to `README.md`
and `AGENTS.md`. Specifically:

- If a recipe is added, removed, or renamed, update the usage block in both files.
- If a recipe's behavior, prerequisites, or workflow changes materially, update the
  prose description in `AGENTS.md` and any relevant steps in `README.md`.
- README.md and AGENTS.md changes should be committed separately from Justfile
  changes so each commit remains atomic and focused.
