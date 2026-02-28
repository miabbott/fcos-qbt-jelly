# ============================================================
# fcos-qbt-jelly Justfile
# ============================================================
# Prerequisites: podman, python3, firewall-cmd
#
# Usage:
#   just          # transpile + validate
#   just serve    # transpile + validate + serve over HTTP
#   just clean    # remove generated .ign file
# ============================================================

bu_file  := "fcos-qbt-jelly.bu"
ign_file := "fcos-qbt-jelly.ign"
http_port := "8000"

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

# Open the firewall port, serve the .ign file, then close the port on exit
serve: validate
    #!/usr/bin/env bash
    set -euo pipefail

    PORT={{http_port}}
    IGN={{ign_file}}

    # Determine local IP (first non-loopback address)
    LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ { print $7; exit }')

    # Check whether the firewall port is already open
    ALREADY_OPEN=false
    if firewall-cmd --zone=public --query-port="${PORT}/tcp" &>/dev/null; then
        ALREADY_OPEN=true
        echo ">>> Firewall port ${PORT}/tcp already open"
    else
        echo ">>> Opening firewall port ${PORT}/tcp"
        if ! sudo firewall-cmd --zone=public --add-port="${PORT}/tcp"; then
            echo "ERROR: Could not open firewall port ${PORT}/tcp" >&2
            exit 1
        fi
    fi

    # Always close the port on exit if we opened it
    cleanup() {
        if [ "${ALREADY_OPEN}" = "false" ]; then
            echo ""
            echo ">>> Closing firewall port ${PORT}/tcp"
            sudo firewall-cmd --zone=public --remove-port="${PORT}/tcp"
        fi
        echo ">>> Done"
    }
    trap cleanup EXIT

    echo ""
    echo ">>> Serving ${IGN} at:"
    echo "    http://${LOCAL_IP}:${PORT}/${IGN}"
    echo ""
    echo "    On the target (live ISO shell), run:"
    echo "    sudo coreos-installer install /dev/sdX \\"
    echo "      --ignition-url http://${LOCAL_IP}:${PORT}/${IGN} \\"
    echo "      --insecure-ignition"
    echo ""
    echo "    Press Ctrl-C when installation is complete."
    echo ""

    python3 -m http.server "${PORT}"

# Remove generated Ignition JSON
clean:
    @echo ">>> Removing {{ign_file}}"
    rm -f {{ign_file}}
    @echo ">>> Clean OK"
