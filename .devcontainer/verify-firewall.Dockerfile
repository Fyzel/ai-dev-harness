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
#
# cosign is baked in at build time (unrestricted network) so it's available for
# a manual `cosign verify` check against a real signed image once the firewall
# is up, without needing runtime egress to GitHub's release-asset CDN:
#   docker run --rm -it --cap-add=NET_ADMIN --cap-add=NET_RAW \
#     --network fw-verify-net --entrypoint bash ai-dev-harness-fw-verify -c '
#       /usr/local/bin/init-firewall.sh &&
#       cosign verify \
#         --certificate-identity-regexp "^https://github\.com/Fyzel/ai-dev-harness/\.github/workflows/build-image\.yml@refs/(heads/(main|dev)|tags/v.*)\$" \
#         --certificate-oidc-issuer https://token.actions.githubusercontent.com \
#         ghcr.io/fyzel/ai-dev-harness:dev
#     '
FROM node:22

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

# cosign, pinned + checksummed, for manual verify testing (see usage note above).
# TARGETARCH (set automatically by buildx) picks the matching release asset,
# so this also works on an arm64 host (e.g. Apple Silicon) instead of pulling
# an amd64 binary that would fail with "exec format error" on a native build.
ARG COSIGN_VERSION=3.1.1
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      amd64) COSIGN_SHA256="ae1ecd212663f3693ad9edf8b1a183900c9a52d3155ba6e354237f9a0f6463fc" ;; \
      arm64) COSIGN_SHA256="2ec865872e331c32fd12b08dae15332d3f92c0aa029219589684a4903ca85d11" ;; \
      *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac \
  && curl -fsSL -o /usr/local/bin/cosign \
       "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${TARGETARCH}" \
  && echo "${COSIGN_SHA256}  /usr/local/bin/cosign" | sha256sum -c - \
  && chmod +x /usr/local/bin/cosign

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh

# Runs as root (default) — iptables/ipset require it. The script's built-in
# verification block (example.com blocked, api.github.com reachable, telemetry
# blocked) exits non-zero on failure, so the `docker run` exit code is the
# pass/fail signal.
ENTRYPOINT ["/usr/local/bin/init-firewall.sh"]
