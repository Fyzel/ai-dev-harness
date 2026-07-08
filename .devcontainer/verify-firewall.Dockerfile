# verify-firewall.Dockerfile
#
# Standalone Linux image to verify .devcontainer/init-firewall.sh from a Windows
# host (via Docker Desktop) without spinning up the full VS Code devcontainer.
# Mirrors the firewall tooling the real devcontainer installs, so a passing run
# means the egress rules build and enforce correctly on real Linux.
#
# Must run with NET_ADMIN/NET_RAW and on a USER-DEFINED network, so Docker's
# embedded DNS resolver (127.0.0.11) is present — the default bridge lacks it and
# the firewall only permits DNS to 127.0.0.11.
#
#   docker build -f .devcontainer/verify-firewall.Dockerfile \
#     -t ai-dev-harness-fw-verify .devcontainer
#   docker network create fw-verify-net
#   docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
#     --network fw-verify-net ai-dev-harness-fw-verify
#
# Or simply: bin/verify-firewall
FROM node:20

# Same firewall tooling as the devcontainer image, for a faithful check.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      iptables \
      ipset \
      iproute2 \
      dnsutils \
      aggregate \
      gh \
      jq \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh

# Runs as root (default) — iptables/ipset require it. The script's built-in
# verification block (example.com blocked, api.github.com reachable, telemetry
# blocked) exits non-zero on failure, so the `docker run` exit code is the
# pass/fail signal.
ENTRYPOINT ["/usr/local/bin/init-firewall.sh"]
