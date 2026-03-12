# ============================================================
# fcos-qbt-jelly Justfile
# ============================================================
# Prerequisites: podman, python3, firewall-cmd, coreos-installer
#
# Usage:
#   just                      # transpile + validate
#   just serve                # transpile + validate + serve .ign in background
#   just stop                 # stop the background server and close firewall port
#   just write-iso /dev/sdX   # download latest FCOS live ISO and write to USB
#   just vm-install           # iterate on ignition config using a local libvirt VM
#   just vm-clean             # remove cached QCOW2 base image
#   just clean                # remove generated .ign file and server pid file
# ============================================================

bu_file  := "fcos-qbt-jelly.bu"
ign_file := "fcos-qbt-jelly.ign"
http_port := "8000"
pid_file  := ".server.pid"

butane   := "podman run --interactive --rm -v .:/work:ro,z -w /work quay.io/coreos/butane:release"
validate := "podman run --pull=always --rm --interactive quay.io/coreos/ignition-validate:release"

# VM iteration settings
vm_name       := "fcos-qbt-jelly"
vm_base_image := "fcos-qbt-jelly-base.qcow2"
vm_overlay    := "/var/lib/libvirt/images/fcos-qbt-jelly-overlay.qcow2"

# Default: transpile and validate
default: validate

# Transpile the Butane YAML to Ignition JSON
transpile:
    @echo ">>> Transpiling {{bu_file}} -> {{ign_file}}"
    {{butane}} --pretty --strict --files-dir /work {{bu_file}} > {{ign_file}}
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

    # Stop any previously running server before starting a new one
    if [ -f "${PID_FILE}" ]; then
        OLD_PID=$(sed -n '1p' "${PID_FILE}")
        OLD_OPENED=$(sed -n '2p' "${PID_FILE}")
        if kill "${OLD_PID}" 2>/dev/null; then
            echo ">>> Stopped previous server (PID ${OLD_PID})"
        else
            echo ">>> Previous server (PID ${OLD_PID}) was not running"
        fi
        if [ "${OLD_OPENED}" = "true" ]; then
            sudo firewall-cmd --zone=public --remove-port="${PORT}/tcp" &>/dev/null || true
        fi
        rm -f "${PID_FILE}"
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
# Usage: just write-iso /dev/sdX
write-iso disk:
    #!/usr/bin/env bash
    set -euo pipefail

    DISK="{{disk}}"

    # Refuse to write to an obviously wrong target
    if [ ! -b "${DISK}" ]; then
        echo "ERROR: '${DISK}' is not a block device. Usage: just write-iso /dev/sdX" >&2
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

    ISO=$(ls -1t fedora-coreos-*-live-iso.x86_64.iso 2>/dev/null | head -1)
    if [ -z "${ISO}" ]; then
        echo "ERROR: could not find downloaded ISO" >&2
        exit 1
    fi

    echo ">>> Writing ${ISO} to ${DISK}..."
    sudo dd if="${ISO}" of="${DISK}" bs=4M status=progress oflag=sync

    echo ""
    echo ">>> Done. You can now boot the target system from ${DISK}."

# Boot a local libvirt VM with the generated Ignition config for iterative testing.
#
# Each run is a clean slate: any existing VM named {{vm_name}} is destroyed and
# its disk removed from the default libvirt pool before a fresh VM is defined.
#
# The QCOW2 base image is downloaded once and cached in the working directory;
# subsequent runs reuse it.  libvirt creates a disposable overlay on top of the
# base image via --disk backing_store so the cached image is never modified.
# The Ignition config is passed directly via the QEMU fw_cfg device — no ISO
# customization step is required.
#
# Prerequisites (host): virt-install, virsh, podman
# Libvirt network: 'default' (virbr0) must be active.
vm-install: validate
    #!/usr/bin/env bash
    set -euo pipefail

    VM_NAME={{vm_name}}
    BASE_IMAGE={{vm_base_image}}
    OVERLAY={{vm_overlay}}
    IGN="$(pwd)/{{ign_file}}"

    # ----------------------------------------------------------------
    # Verify prerequisites
    # ----------------------------------------------------------------
    for cmd in virt-install virsh; do
        if ! command -v "${cmd}" &>/dev/null; then
            echo "ERROR: '${cmd}' not found. Install virt-install / libvirt." >&2
            exit 1
        fi
    done

    # Ensure the libvirt default network is active
    if ! virsh net-list --all 2>/dev/null | awk 'NR>2 && $1=="default" {exit ($2=="active" ? 0 : 1)}'; then
        echo ">>> Starting libvirt 'default' network..."
        virsh net-start default
    fi

    # ----------------------------------------------------------------
    # Clean up any existing VM from a previous iteration
    # ----------------------------------------------------------------
    if virsh dominfo "${VM_NAME}" &>/dev/null; then
        echo ">>> Destroying existing VM '${VM_NAME}'..."
        virsh destroy "${VM_NAME}" 2>/dev/null || true
        virsh undefine "${VM_NAME}" --remove-all-storage 2>/dev/null || true
    fi
    # Remove any leftover overlay not managed by virsh
    sudo rm -f "${OVERLAY}"

    # ----------------------------------------------------------------
    # Download the QCOW2 base image (cached across runs)
    # ----------------------------------------------------------------
    if [ -f "${BASE_IMAGE}" ]; then
        echo ">>> Using cached base image: ${BASE_IMAGE}"
    else
        echo ">>> No cached base image found — downloading latest stable Fedora CoreOS QCOW2..."
        podman run --pull=always --privileged --rm \
            -v .:/data -w /data \
            quay.io/coreos/coreos-installer:release \
            download --stream stable --platform qemu --format qcow2.xz --decompress
        DOWNLOADED=$(ls -1t fedora-coreos-*-qemu.x86_64.qcow2 2>/dev/null | head -1 || true)
        if [ -z "${DOWNLOADED}" ]; then
            echo "ERROR: QCOW2 download succeeded but file not found." >&2
            exit 1
        fi
        mv "${DOWNLOADED}" "${BASE_IMAGE}"
        echo ">>> Downloaded and cached as: ${BASE_IMAGE}"
    fi
    BASE_IMAGE_PATH="$(pwd)/${BASE_IMAGE}"

    # ----------------------------------------------------------------
    # Apply SELinux label so libvirt/QEMU can read the Ignition config
    # ----------------------------------------------------------------
    chcon --type svirt_home_t "${IGN}"

    # ----------------------------------------------------------------
    # Define and start the VM
    #
    # --import boots directly from the QCOW2 base image; no installer
    # step is needed.  --disk backing_store= tells libvirt to create a
    # throwaway overlay on top of the base image — the base is never
    # modified.  The Ignition config is delivered via the QEMU fw_cfg
    # device, which is the mechanism FCOS expects on the qemu platform.
    # --noautoconsole lets virt-install return immediately; we then
    # attach virsh console ourselves.
    # ----------------------------------------------------------------
    echo ">>> Launching VM '${VM_NAME}'..."
    virt-install \
        --connect qemu:///system \
        --name "${VM_NAME}" \
        --ram 4096 \
        --vcpus 2 \
        --os-variant fedora-coreos-stable \
        --import \
        --disk "path=${OVERLAY},backing_store=${BASE_IMAGE_PATH},bus=virtio,size=20" \
        --network network=default \
        --graphics none \
        --console pty,target_type=serial \
        --noautoconsole \
        --qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=${IGN}"

    echo ""
    echo ">>> VM booting. Attaching console (Ctrl-] to detach)..."
    echo ">>> SSH in with: ssh core@\$(virsh domifaddr ${VM_NAME} | awk '/ipv4/{print \$4}' | cut -d/ -f1)"
    echo ""

    virsh console "${VM_NAME}"

# Remove the cached QCOW2 base image used by vm-install
vm-clean:
    @echo ">>> Removing {{vm_base_image}}"
    rm -f {{vm_base_image}}
    @echo ">>> vm-clean OK"

# Remove generated Ignition JSON and server pid file
clean:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -f "{{pid_file}}" ]; then
        just stop
    fi

    echo ">>> Removing {{ign_file}}"
    rm -f {{ign_file}}
    echo ">>> Clean OK"
