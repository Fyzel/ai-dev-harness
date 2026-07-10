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

if ! sudo /usr/local/bin/init-firewall.sh; then
    echo "FATAL: egress firewall failed to initialize; refusing to start." >&2
    echo "       Ensure the container has --cap-add=NET_ADMIN --cap-add=NET_RAW." >&2
    exit 1
fi

exec "$@"
