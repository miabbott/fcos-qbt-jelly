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
#   just clean                # remove generated .ign file and server pid file
# ============================================================

bu_file  := "fcos-qbt-jelly.bu"
ign_file := "fcos-qbt-jelly.ign"
http_port := "8000"
pid_file  := ".server.pid"

butane   := "podman run --interactive --rm quay.io/coreos/butane:release"
validate := "podman run --pull=always --rm --interactive quay.io/coreos/ignition-validate:release"

# VM iteration settings
vm_name   := "fcos-qbt-jelly"
vm_disk   := "fcos-qbt-jelly-vm.qcow2"
vm_disk_gb := "20"
# Host IP on the libvirt default network (virbr0); reachable from the VM without
# any firewall changes since libvirt manages its own bridge rules.
vm_host_ip := "192.168.122.1"

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
# its disk image deleted before a fresh install begins.
#
# The live ISO is downloaded once and cached in the working directory; subsequent
# runs reuse it.  The VM installs FCOS to a scratch qcow2 disk, then reboots into
# the installed OS.  A virsh console session is attached so you can watch the
# install and first-boot output in real time.
#
# Prerequisites (host): virt-install, virsh, qemu-img
# Libvirt network: 'default' (virbr0) must be active; host is at {{vm_host_ip}}.
vm-install: validate
    #!/usr/bin/env bash
    set -euo pipefail

    VM_NAME={{vm_name}}
    VM_DISK={{vm_disk}}
    VM_DISK_GB={{vm_disk_gb}}
    IGN={{ign_file}}
    PORT={{http_port}}
    PID_FILE={{pid_file}}
    HOST_IP={{vm_host_ip}}
    IGN_URL="http://${HOST_IP}:${PORT}/${IGN}"

    # ----------------------------------------------------------------
    # Helpers
    # ----------------------------------------------------------------
    stop_server() {
        if [ -f "${PID_FILE}" ]; then
            local pid opened
            pid=$(sed -n '1p' "${PID_FILE}")
            opened=$(sed -n '2p' "${PID_FILE}")
            if kill "${pid}" 2>/dev/null; then
                echo ">>> Stopped HTTP server (PID ${pid})"
            fi
            # The libvirt bridge does not require a host firewall rule, so
            # OPENED_PORT will always be 'false' in vm-install, but handle it
            # defensively in case the server was started by 'just serve'.
            if [ "${opened}" = "true" ]; then
                sudo firewall-cmd --zone=public --remove-port="${PORT}/tcp" &>/dev/null || true
            fi
            rm -f "${PID_FILE}"
        fi
    }

    # ----------------------------------------------------------------
    # Verify prerequisites
    # ----------------------------------------------------------------
    for cmd in virt-install virsh qemu-img; do
        if ! command -v "${cmd}" &>/dev/null; then
            echo "ERROR: '${cmd}' not found. Install virt-install / libvirt / qemu-img." >&2
            exit 1
        fi
    done

    # Ensure the libvirt default network is active
    if ! virsh net-info default 2>/dev/null | grep -q "Active:.*yes"; then
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
    # Also remove the scratch disk in case it was created outside virsh
    if [ -f "${VM_DISK}" ]; then
        echo ">>> Removing leftover disk image ${VM_DISK}..."
        rm -f "${VM_DISK}"
    fi

    # ----------------------------------------------------------------
    # Download the live ISO (cached across runs)
    # ----------------------------------------------------------------
    ISO=$(ls -1t fedora-coreos-*-live.x86_64.iso 2>/dev/null | head -1 || true)
    if [ -z "${ISO}" ]; then
        echo ">>> No cached ISO found — downloading latest stable Fedora CoreOS live ISO..."
        podman run --pull=always --privileged --rm \
            -v .:/data -w /data \
            quay.io/coreos/coreos-installer:release \
            download --stream stable --platform metal --format iso
        ISO=$(ls -1t fedora-coreos-*-live.x86_64.iso 2>/dev/null | head -1)
        if [ -z "${ISO}" ]; then
            echo "ERROR: ISO download succeeded but file not found." >&2
            exit 1
        fi
        echo ">>> Downloaded: ${ISO}"
    else
        echo ">>> Using cached ISO: ${ISO}"
    fi
    ISO_PATH="$(pwd)/${ISO}"

    # ----------------------------------------------------------------
    # Create the scratch disk image
    # ----------------------------------------------------------------
    echo ">>> Creating ${VM_DISK_GB} GiB scratch disk: ${VM_DISK}"
    qemu-img create -f qcow2 "${VM_DISK}" "${VM_DISK_GB}G"
    DISK_PATH="$(pwd)/${VM_DISK}"

    # ----------------------------------------------------------------
    # Start the HTTP server (bound to all interfaces so virbr0 can reach it)
    # ----------------------------------------------------------------
    stop_server  # clean up any stale server first
    trap stop_server EXIT

    echo ">>> Starting HTTP server on port ${PORT}..."
    python3 -m http.server "${PORT}" &>/tmp/fcos-httpd.log &
    echo "$!" > "${PID_FILE}"
    echo "false" >> "${PID_FILE}"   # we did not open a firewall port
    echo ">>> Ignition URL: ${IGN_URL}"

    # ----------------------------------------------------------------
    # Define and start the VM
    #
    # The live ISO kernel is passed coreos.inst.* arguments via --extra-args
    # so the live environment performs an unattended install and reboots.
    # --noautoconsole lets virt-install return immediately after defining
    # the domain; we then attach virsh console ourselves so the trap fires
    # correctly when the console session ends.
    # ----------------------------------------------------------------
    echo ">>> Launching VM '${VM_NAME}'..."
    virt-install \
        --name "${VM_NAME}" \
        --ram 4096 \
        --vcpus 2 \
        --os-variant fedora-coreos-stable \
        --disk "path=${DISK_PATH},format=qcow2,bus=virtio" \
        --cdrom "${ISO_PATH}" \
        --network network=default \
        --graphics none \
        --console pty,target_type=serial \
        --extra-args "console=ttyS0,115200n8 coreos.inst.install_dev=/dev/vda coreos.inst.ignition_url=${IGN_URL} coreos.inst.insecure" \
        --noautoconsole \
        --boot cdrom,hd

    echo ""
    echo ">>> VM is installing. Attaching console (Ctrl-] to detach)..."
    echo ">>> After the install reboots, FCOS will apply your Ignition config."
    echo ">>> SSH in with: ssh core@\$(virsh domifaddr ${VM_NAME} | awk '/ipv4/{print \$4}' | cut -d/ -f1)"
    echo ""

    virsh console "${VM_NAME}"

    # trap fires here — HTTP server is stopped

# Remove generated Ignition JSON and server pid file
clean:
    @echo ">>> Removing {{ign_file}} and {{pid_file}}"
    rm -f {{ign_file}} {{pid_file}}
    @echo ">>> Clean OK"
