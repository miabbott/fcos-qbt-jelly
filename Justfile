# ============================================================
# fcos-qbt-jelly Justfile
# ============================================================
# Prerequisites: podman, python3, firewall-cmd, coreos-installer
#
# Usage:
#   just                      # transpile + validate
#   just serve                # transpile + validate + serve .ign in background
#   just stop                 # stop the background server and close firewall port
#   just write-iso DISK=/dev/sdX  # download latest FCOS live ISO and write to USB
#   just clean                # remove generated .ign file and server pid file
# ============================================================

bu_file  := "fcos-qbt-jelly.bu"
ign_file := "fcos-qbt-jelly.ign"
http_port := "8000"
pid_file  := ".server.pid"

butane   := "podman run --interactive --rm quay.io/coreos/butane:release"
validate := "podman run --pull=always --rm --interactive quay.io/coreos/ignition-validate:release"

# Default: transpile and validate
default: validate

# Transpile the Butane YAML to Ignition JSON
transpile:
    @echo ">>> Transpiling {{bu_file}} -> {{ign_file}}"
    {{butane}} --pretty --strict < {{bu_file}} > {{ign_file}}
    @echo ">>> Transpile OK"

# Validate the generated Ignition JSON
validate: transpile
    @echo ">>> Validating {{ign_file}}"
    {{validate}} - < {{ign_file}}
    @echo ">>> Validation OK"

# Spawn the HTTP server in the background and open the firewall port.
# Run 'just stop' when the target installation is complete.
serve: validate
    #!/usr/bin/env bash
    set -euo pipefail

    PORT={{http_port}}
    IGN={{ign_file}}
    PID_FILE={{pid_file}}

    if [ -f "${PID_FILE}" ]; then
        echo "ERROR: server already running (PID $(cat ${PID_FILE})). Run 'just stop' first." >&2
        exit 1
    fi

    # Determine local IP (first non-loopback address)
    LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ { print $7; exit }')

    # Open firewall port if not already open; record whether we opened it
    if firewall-cmd --zone=public --query-port="${PORT}/tcp" &>/dev/null; then
        echo ">>> Firewall port ${PORT}/tcp already open"
        OPENED_PORT=false
    else
        echo ">>> Opening firewall port ${PORT}/tcp"
        if ! sudo firewall-cmd --zone=public --add-port="${PORT}/tcp"; then
            echo "ERROR: Could not open firewall port ${PORT}/tcp" >&2
            exit 1
        fi
        OPENED_PORT=true
    fi

    # Start server in background, redirect output to a log file
    python3 -m http.server "${PORT}" &>/tmp/fcos-httpd.log &
    echo "$!" > "${PID_FILE}"
    echo "${OPENED_PORT}" >> "${PID_FILE}"

    echo ""
    echo ">>> Server running (PID $(head -1 ${PID_FILE})) — logs at /tmp/fcos-httpd.log"
    echo ">>> Serving ${IGN} at:"
    echo "    http://${LOCAL_IP}:${PORT}/${IGN}"
    echo ""
    echo "    On the target (live ISO shell), run:"
    echo "    sudo coreos-installer install /dev/sdX \\"
    echo "      --ignition-url http://${LOCAL_IP}:${PORT}/${IGN} \\"
    echo "      --insecure-ignition"
    echo ""
    echo ">>> Run 'just stop' when installation is complete."

# Stop the background HTTP server and close the firewall port if we opened it.
stop:
    #!/usr/bin/env bash
    set -euo pipefail

    PORT={{http_port}}
    PID_FILE={{pid_file}}

    if [ ! -f "${PID_FILE}" ]; then
        echo "ERROR: no PID file found (${PID_FILE}). Is the server running?" >&2
        exit 1
    fi

    PID=$(sed -n '1p' "${PID_FILE}")
    OPENED_PORT=$(sed -n '2p' "${PID_FILE}")

    if kill "${PID}" 2>/dev/null; then
        echo ">>> Stopped server (PID ${PID})"
    else
        echo ">>> Server (PID ${PID}) was not running"
    fi

    if [ "${OPENED_PORT}" = "true" ]; then
        echo ">>> Closing firewall port ${PORT}/tcp"
        sudo firewall-cmd --zone=public --remove-port="${PORT}/tcp"
    fi

    rm -f "${PID_FILE}"
    echo ">>> Done"

# Download the latest stable Fedora CoreOS live ISO and write it to a USB key.
# Usage: just write-iso DISK=/dev/sdX
# The DISK variable must be set — there is no default to avoid accidents.
write-iso DISK="":
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -z "{{DISK}}" ]; then
        echo "ERROR: DISK is required. Usage: just write-iso DISK=/dev/sdX" >&2
        exit 1
    fi

    DISK="{{DISK}}"

    # Refuse to write to an obviously wrong target
    if [ ! -b "${DISK}" ]; then
        echo "ERROR: ${DISK} is not a block device" >&2
        exit 1
    fi

    # Warn if the target looks like an internal disk (sda/nvme0n1 with no partition suffix)
    if lsblk -d -o TRAN "${DISK}" 2>/dev/null | grep -qE '^(sata|nvme)$'; then
        echo "WARNING: ${DISK} appears to be an internal disk ($(lsblk -d -o TRAN "${DISK}" | tail -1))."
        read -r -p "         Are you sure you want to write to ${DISK}? [y/N] " CONFIRM
        [[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
    fi

    echo ">>> Downloading latest stable Fedora CoreOS live ISO..."
    podman run --pull=always --privileged --rm \
        -v .:/data -w /data \
        quay.io/coreos/coreos-installer:release \
        download --stream stable --platform metal --format iso

    ISO=$(ls -1t fedora-coreos-*-live.x86_64.iso 2>/dev/null | head -1)
    if [ -z "${ISO}" ]; then
        echo "ERROR: could not find downloaded ISO" >&2
        exit 1
    fi

    echo ">>> Writing ${ISO} to ${DISK}..."
    sudo dd if="${ISO}" of="${DISK}" bs=4M status=progress oflag=sync

    echo ""
    echo ">>> Done. You can now boot the target system from ${DISK}."

# Remove generated Ignition JSON and server pid file
clean:
    @echo ">>> Removing {{ign_file}} and {{pid_file}}"
    rm -f {{ign_file}} {{pid_file}}
    @echo ">>> Clean OK"
