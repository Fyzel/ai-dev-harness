#!/bin/bash
set -euo pipefail

# Container entrypoint: program the egress firewall BEFORE handing control to the
# requested command, so no process runs with unrestricted network access.
#
# This makes the firewall enforced on every `podman run` / `docker run`, not only
# under a dev container (where devcontainer.json's postStartCommand handles it).
#
# Requirements (same as the dev container):
#   - NET_ADMIN + NET_RAW capabilities (podman/docker: --cap-add=NET_ADMIN --cap-add=NET_RAW)
#   - the node sudoers rule permitting the firewall script (baked into the image)
#
# Fail-closed: if the firewall cannot be programmed, we refuse to start rather
# than expose an unrestricted container. To intentionally run WITHOUT the
# firewall (e.g. debugging), override the entrypoint:
#   podman run --entrypoint /bin/bash <image>

# Program the firewall quietly: capture its (verbose) output and surface it only
# on failure, so a normal start is clean while diagnostics survive when it matters.
# Set FIREWALL_VERBOSE=1 to stream the full output instead.
#
# The capture file is created ONLY in the non-verbose path, so verbose mode has no
# dependency on a writable /tmp or a working mktemp.
fw_rc=0
if [ "${FIREWALL_VERBOSE:-0}" = "1" ]; then
    sudo /usr/local/bin/init-firewall.sh || fw_rc=$?
else
    fw_log=$(mktemp)
    # SC2024: the redirect targets a node-owned mktemp file written by this shell,
    # not a root-owned path, so sudo's output is captured correctly here.
    # shellcheck disable=SC2024
    sudo /usr/local/bin/init-firewall.sh >"$fw_log" 2>&1 || fw_rc=$?
fi
if [ "$fw_rc" -ne 0 ]; then
    if [ -n "${fw_log:-}" ]; then
        cat "$fw_log" >&2
        rm -f "$fw_log"
    fi
    echo "FATAL: egress firewall failed to initialize; refusing to start." >&2
    echo "       Ensure the container has --cap-add=NET_ADMIN --cap-add=NET_RAW." >&2
    exit 1
fi
if [ -n "${fw_log:-}" ]; then
    rm -f "$fw_log"
fi

exec "$@"
