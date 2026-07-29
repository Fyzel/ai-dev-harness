FROM ubuntu:26.04

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# Install basic development tools and iptables/ipset (needed by init-firewall.sh)
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  wget \
  less \
  git \
  procps \
  sudo \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  iputils-ping \
  dnsutils \
  aggregate \
  jq \
  python3.14 \
  python3.14-venv \
  vim \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Node.js explicitly — unlike node:22, this base doesn't ship it.
# Pinned tarball + per-arch sha256 checked against nodejs.org's published
# SHASUMS256.txt, matching the checksum-pin pattern already used for
# git-delta/cosign in this repo rather than adding a NodeSource apt trust root.
# Bumping NODE_VERSION requires updating both sha256 checksums below it to
# match — they are hardcoded per-architecture, not derived from the version.
ARG NODE_VERSION=24.18.0
RUN set -eu; \
  case "$(dpkg --print-architecture)" in \
    amd64) NODE_ARCH="x64"; NODE_SHA256="783130984963db7ba9cbd01089eaf2c2efb055c7c1693c943174b967b3050cb8" ;; \
    arm64) NODE_ARCH="arm64"; NODE_SHA256="6b4484c2190274175df9aa8f28e2d758a819cb1c1fe6ab481e2f95b463ab8508" ;; \
    *) echo "Unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
  esac; \
  curl -fsSL -o /tmp/node.tar.gz \
    "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz"; \
  echo "${NODE_SHA256}  /tmp/node.tar.gz" | sha256sum -c -; \
  tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1 \
    --no-same-owner --exclude='*.md'; \
  rm /tmp/node.tar.gz; \
  node --version && npm --version

# Create the node user (unlike node:22, this base doesn't ship with it).
# Remove ubuntu user (uid 1000) and explicitly create node at uid 1000 to match
# what node:22 had — this ensures volume mounts expecting uid 1000 work correctly.
RUN userdel -r ubuntu && groupadd -g 1000 node && useradd -m -u 1000 -g 1000 -s /bin/bash node \
  && [ "$(id -u node)" = 1000 ] && [ "$(id -g node)" = 1000 ]

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history across rebuilds (backed by the /commandhistory volume).
RUN mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory \
  && echo "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
     >> /home/$USERNAME/.bashrc \
  && echo "alias l='ls -la'" >> /home/$USERNAME/.bashrc \
  && echo "alias claude-yolo='claude --dangerously-skip-permissions'" >> /home/$USERNAME/.bashrc

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Pin Claude Code config/auth to a fixed dir so it is identical whether the image
# is launched via the dev container OR run directly (podman/docker run). Mount a
# persistent volume at this path to keep the login across runs.
ENV CLAUDE_CONFIG_DIR=/home/node/.claude

# Same reasoning for `gh`: pin its config/auth dir so a mounted volume survives
# rebuilds instead of `gh auth login` being lost every run (see issue #35).
ENV GH_CONFIG_DIR=/home/node/.config/gh

# Create workspace and config directories and set permissions.
# 0700 on the auth dirs: they hold OAuth/PAT tokens, so keep them unreadable to
# anyone but the node user even though the container is single-tenant.
RUN mkdir -p /workspace /home/node/.claude /home/node/.config/gh && \
  chown -R node:node /workspace /home/node/.claude /home/node/.config/gh && \
  chmod 0700 /home/node/.claude /home/node/.config/gh

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Install trivy from the official Aquasecurity apt repo (non-snap — snapd
# doesn't run in this container's non-root, minimal-capability setup — see
# issue #49). This adds a new apt trust root (unlike Node/git-delta's
# checksum-pinned downloads) because that's the officially documented
# install path: https://trivy.dev/docs/latest/getting-started/installation/
# Pinned to an exact version via apt, matching NODE_VERSION/GIT_DELTA_VERSION.
# Vulnerability/Java DB pulls happen at container *runtime* against GHCR, not
# at build time — see the ghcr.io / pkg-containers.githubusercontent.com
# entries added to init-firewall.sh's allowlist for that.
#
# The signing key's fingerprint is pinned below and checked before it's
# trusted. Aquasecurity's install docs don't publish this fingerprint
# independently, so this can't be cross-verified against a second source —
# but pinning still converts silent trust-on-first-use into a fail-closed
# check against a future key rotation or a compromised mirror serving a
# different key. Fingerprint captured 2026-07-28 via `gpg --show-keys
# --with-fingerprint` against the URL below; if Aquasecurity rotates their
# key, update TRIVY_KEY_FINGERPRINT after verifying the new key out-of-band.
ARG TRIVY_VERSION=0.72.0
ARG TRIVY_KEY_FINGERPRINT=825AD9036F7C850E6A6FED4935B8ACA44FD9CA9F
RUN set -eu; \
  wget -qO /tmp/trivy-key.asc https://aquasecurity.github.io/trivy-repo/deb/public.key; \
  actual_fpr=$(gpg --show-keys --with-fingerprint --with-colons /tmp/trivy-key.asc | awk -F: '/^fpr:/ {print $10; exit}'); \
  if [ "$actual_fpr" != "$TRIVY_KEY_FINGERPRINT" ]; then \
    echo "ERROR: trivy signing key fingerprint mismatch: expected $TRIVY_KEY_FINGERPRINT, got $actual_fpr" >&2; \
    exit 1; \
  fi; \
  gpg --dearmor < /tmp/trivy-key.asc | tee /usr/share/keyrings/trivy.gpg > /dev/null; \
  rm /tmp/trivy-key.asc; \
  echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
    > /etc/apt/sources.list.d/trivy.list; \
  apt-get update; \
  apt-get install -y --no-install-recommends "trivy=${TRIVY_VERSION}"; \
  apt-get clean && rm -rf /var/lib/apt/lists/*; \
  rm /etc/apt/sources.list.d/trivy.list /usr/share/keyrings/trivy.gpg; \
  trivy --version

# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default shell to bash
ENV SHELL=/bin/bash

# Set the default editor and visual
ENV EDITOR=vim
ENV VISUAL=vim

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Enforce telemetry / non-essential-traffic opt-out at the highest settings precedence.
# managed-settings.json overrides ~/.claude and project .claude, so these opt-outs
# cannot be silently re-enabled from inside the container.
USER root
RUN mkdir -p /etc/claude-code
COPY managed-settings.json /etc/claude-code/managed-settings.json
RUN chmod 0644 /etc/claude-code/managed-settings.json

# Copy and set up firewall script
COPY init-firewall.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall

# Entrypoint programs the egress firewall on every container start (any runtime,
# not just dev containers), then execs the requested command. Fail-closed.
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh
USER node

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]