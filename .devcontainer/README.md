# Claude Code dev container (restricted egress)

Runs Claude Code inside a Docker dev container with **persistent authentication**
and a **default-deny egress firewall** that also blocks optional telemetry.

Based on the [official reference container](https://code.claude.com/docs/en/devcontainer),
modified so telemetry/error-reporting endpoints are blocked rather than allowed.

## Files

| File                    | Role                                                                                                     |
|-------------------------|----------------------------------------------------------------------------------------------------------|
| `devcontainer.json`     | Volume mounts, `NET_ADMIN`/`NET_RAW` capabilities, telemetry-opt-out env, runs the firewall on start     |
| `Dockerfile`            | `node:20` base, dev tooling, `iptables`/`ipset`, Claude Code install, firewall + managed-settings + entrypoint wiring |
| `init-firewall.sh`      | Programs iptables/ipset: default-DROP egress, allowlist only                                             |
| `entrypoint.sh`         | Runs `init-firewall.sh` on every container start then execs the command (fail-closed) — enforces egress on a raw `docker`/`podman run`, not only the dev container |
| `managed-settings.json` | Telemetry opt-out at highest settings precedence (cannot be re-enabled from inside the container)        |

## Usage

1. Install VS Code + the **Dev Containers** extension, and Docker.
2. Open this repo in VS Code → Command Palette → **Dev Containers: Rebuild Container**.
3. Open a terminal in the container, run `claude`, follow the sign-in prompt.

First start fetches GitHub IP ranges and resolves the allowlisted domains. Watch the
`postStartCommand` output for `Firewall verification passed` lines. The firewall
re-runs on every container start (`postStartCommand`), so it survives restarts.

Outside the dev container, the image `ENTRYPOINT` (`entrypoint.sh`) programs the
firewall before running your command, so a plain `docker`/`podman run` is locked
down too — provided you pass `--cap-add=NET_ADMIN --cap-add=NET_RAW`. It is
fail-closed: if the firewall can't be programmed, the container refuses to start.
To bypass it deliberately (debugging), override with `--entrypoint /bin/bash`.

## Persistent authentication

The container home directory is discarded on rebuild. Two named volumes preserve state:

| Volume                                      | Mount                | Holds                                      |
|---------------------------------------------|----------------------|--------------------------------------------|
| `claude-code-config-${devcontainerId}`      | `/home/node/.claude` | Auth token, user settings, session history |
| `claude-code-bashhistory-${devcontainerId}` | `/commandhistory`    | Shell history                              |

`CLAUDE_CONFIG_DIR` points Claude Code at `/home/node/.claude`. `${devcontainerId}`
scopes the volumes to **this project** — other repos get their own auth/state, not a
shared one. Sign in once; rebuilds keep you signed in.

To wipe persisted auth (e.g. sign out fully), remove the volumes on the host:

```bash
docker volume ls | grep claude-code-config
docker volume rm <volume-name>
```

## Egress firewall

`init-firewall.sh` sets the iptables `OUTPUT` policy to `DROP` and permits only traffic
to an `ipset` allowlist. Everything else is `REJECT`ed.

Allowed:

| Destination                                                                                    | Why                                                 |
|------------------------------------------------------------------------------------------------|-----------------------------------------------------|
| GitHub meta IP ranges (`api.github.com/meta`)                                                  | git / `gh` / clones                                 |
| `registry.npmjs.org`                                                                           | npm package installs                                |
| `api.anthropic.com`                                                                            | Claude API **and** the WebFetch domain-safety check |
| `claude.ai`                                                                                    | claude.ai account sign-in + install script          |
| `platform.claude.com`                                                                          | Anthropic Console sign-in                           |
| `downloads.claude.ai`                                                                          | Claude Code self-updater (release binaries + keys)  |
| `marketplace.visualstudio.com`, `vscode.blob.core.windows.net`, `update.code.visualstudio.com` | VS Code server + extensions                         |
| `deb.debian.org`, `security.debian.org`                                                        | Debian `apt` packages at runtime (CDN — see note)   |
| Host gateway (`/32`), DNS to `resolv.conf` nameservers, loopback                               | Container plumbing (gateway only — no siblings, no blanket SSH) |

### Telemetry: blocked, two layers

**Network** — these are deliberately **left out** of the allowlist, so outbound
telemetry cannot leave the container:

- `sentry.io` — error reporting
- `statsig.anthropic.com` — metrics
- `statsig.com` — metrics

The script's verification step **fails the build/start** if `sentry.io` or
`statsig.anthropic.com` become reachable.

**Application** — env vars opt out at the source (set in `containerEnv` and enforced
via `managed-settings.json`):

`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_TELEMETRY`,
`DISABLE_ERROR_REPORTING`, `DISABLE_FEEDBACK_COMMAND`,
`CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY`.

> `api.anthropic.com` stays allowed because it carries the Claude API itself. It also
> serves the WebFetch domain-safety check (hostname only — no code, paths, or page
> content). That check is not telemetry and cannot be split off at the DNS layer. To
> turn it off, set `"skipWebFetchPreflight": true` in settings.

## Adding an allowed domain

Edit the `for domain in ... ` loop in `init-firewall.sh`, add the hostname, then
rebuild (or re-run `sudo /usr/local/bin/init-firewall.sh` inside the container):

```bash
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "your.new-domain.example" \
    ...
```

Notes:

- The firewall resolves each domain to IPs at start time and allowlists those IPs.
  Domains behind rotating IPs / CDNs may need a re-run if their IPs change.
- For an [MCP server](https://code.claude.com/docs/en/mcp) with a remote endpoint,
  add its domain here **and** define the server at project scope in `.mcp.json`.
- Removing a domain (e.g. a VS Code host you don't use) tightens egress further —
  just delete its line.

## Requirements & caveats

- Needs `--cap-add=NET_ADMIN --cap-add=NET_RAW` (already in `runArgs`) so the script
  can program iptables. Rootless Docker or hosts that forbid these capabilities can't
  run the in-container firewall — rely on host/network controls instead.
- `*.sh` is pinned to LF via `.gitattributes`; CRLF checkouts break the shebang in Linux.
- Per the upstream warning: a dev container is a strong boundary, not absolute. Use it
  with trusted repositories, and avoid mounting host secrets (`~/.ssh`, cloud creds).
