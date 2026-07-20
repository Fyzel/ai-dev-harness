FROM node:22

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
  vim \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

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

# Make bash the node user's login shell (base image may leave it as /bin/sh).
RUN usermod -s /bin/bash node

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