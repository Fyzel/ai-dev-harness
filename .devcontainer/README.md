# Claude Code dev container (restricted egress)

Runs Claude Code inside a Docker dev container with **persistent authentication**
and a **default-deny egress firewall** that also blocks optional telemetry.

Based on the [official reference container](https://code.claude.com/docs/en/devcontainer),
modified so telemetry/error-reporting endpoints are blocked rather than allowed.

## Files

| File                    | Role                                                                                                     |
|-------------------------|----------------------------------------------------------------------------------------------------------|
| `devcontainer.json`     | Volume mounts, `NET_ADMIN`/`NET_RAW` capabilities, telemetry-opt-out env, runs the firewall on start     |
| `Dockerfile`            | `node:22` base, dev tooling, `iptables`/`ipset`, Claude Code install, firewall + managed-settings + entrypoint wiring |
| `init-firewall.sh`      | Programs iptables/ipset: default-DROP egress, allowlist only                                             |
| `entrypoint.sh`         | Runs `init-firewall.sh` on every container start then execs the command (fail-closed) — enforces egress on a raw `docker`/`podman run`, not only the dev container |
| `managed-settings.json` | Telemetry opt-out at highest settings precedence (cannot be re-enabled from inside the container)        |

## Usage

1. Install VS Code + the **Dev Containers** extension, and a container engine (Docker or Podman).
2. Open this repo in VS Code → Command Palette → **Dev Containers: Rebuild Container**.
3. Open a terminal in the container, run `claude`, follow the sign-in prompt.

### Docker vs Podman backend

**Podman is recommended** over Docker on Windows, Linux, and macOS. Docker's
usual deployment relies on a long-running `dockerd` daemon running as root,
with a Unix socket that is effectively root-equivalent — anyone who can reach
it can mount the host filesystem or launch a privileged container. Docker does
have a rootless mode, but it's opt-in and less commonly deployed. Podman is
daemonless and rootless by default: there's no persistent root process, and
containers are forked directly under the invoking user, so that's the standard
Podman experience rather than a bolt-on. Note that `NET_ADMIN`/`NET_RAW` behave
a bit differently under rootless Podman — the capability applies within the
container's own user/network namespace (via `slirp4netns`/`pasta`), not the
host's real network stack. That's still sufficient here, since the firewall
only needs to constrain the container's own egress, not the host's.

The config is standard Dev Containers spec and works with either engine. To use
**Podman**, point the extension at it in VS Code settings (no repo change):

```jsonc
// settings.json
"dev.containers.dockerPath": "podman"
```

On WSL, run this against your Podman-enabled distro. The `:Z` SELinux relabel is
generally unneeded on WSL; add it to the workspace mount only if you hit
permission errors.

> In the VS Code path the extension sets `overrideCommand` (default for
> Dockerfile-based configs), replacing the image command with its own keep-alive
> loop — so the image `ENTRYPOINT` is bypassed and the firewall is programmed by
> `postStartCommand` instead. The `ENTRYPOINT` is the enforcement path for a raw
> `docker`/`podman run`. Both paths end up firewalled.

First start fetches GitHub IP ranges and resolves the allowlisted domains. Watch the
`postStartCommand` output for `Firewall verification passed` lines. The firewall
re-runs on every container start (`postStartCommand`), so it survives restarts.

Outside the dev container, the image `ENTRYPOINT` (`entrypoint.sh`) programs the
firewall before running your command, so a plain `docker`/`podman run` is locked
down too — provided you pass `--cap-add=NET_ADMIN --cap-add=NET_RAW`. It is
fail-closed: if the firewall can't be programmed, the container refuses to start.
To bypass it deliberately (debugging), override with `--entrypoint /bin/bash`.

The entrypoint runs the firewall **quietly** — its verbose per-rule output is
suppressed on a successful start and replayed only if it fails. Set
`FIREWALL_VERBOSE=1` (e.g. `-e FIREWALL_VERBOSE=1`) to stream the full output.
(Note: the dev container's `postStartCommand` path is unaffected and still logs
verbosely to the dev-container startup log.)

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
| `tuf-repo-cdn.sigstore.dev`                                                                     | Sigstore TUF root of trust, for `cosign verify` (Fulcio/Rekor/CT keys) |
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
