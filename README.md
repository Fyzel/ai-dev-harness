# ai-dev-harness

A personalized, security-hardened harness for running **Claude Code** inside a
container: a default-deny egress firewall, blocked telemetry, and persistent
authentication — published as a ready-to-run image on GHCR, plus helper scripts
for building it, verifying the firewall, and opening AI-assisted pull requests.

## What's in here

| Path                     | Purpose                                                                                                                                                                                        |
|--------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `.devcontainer/`         | The hardened Claude Code container: Dockerfile, egress firewall, persistent-auth volumes, telemetry opt-out. See [`.devcontainer/README.md`](.devcontainer/README.md) for the firewall detail. |
| `bin/build-image`        | Build and optionally push the image to `ghcr.io/<owner>/ai-dev-harness`.                                                                                                                       |
| `bin/verify-firewall`    | Build and run the firewall in a throwaway image to confirm the egress rules enforce.                                                                                                           |
| `bin/create-pr`          | Generate a PR title/description from your commits + diff using a local **Ollama** model, then open the PR via `gh`.                                                                            |
| `.github/workflows/`     | CI: build/push the image (`build-image.yml`) and lint workflows with actionlint (`lint-actions.yml`).                                                                                          |
| `ollama-dev.sample.json` | Sample config for `bin/create-pr`'s Ollama backends — copy to `ollama-dev.json` (gitignored).                                                                                                  |

## The container

Claude Code runs as the non-root `node` user with:

- **Default-deny egress firewall** (`init-firewall.sh`) — only an allowlist of
  required hosts (GitHub, npm, Anthropic APIs, VS Code, Debian mirrors, the
  Claude Code updater) is reachable; everything else is rejected. IPv6 is locked
  down. Telemetry endpoints are deliberately excluded.
- **Telemetry off at the source** — `DISABLE_*` env vars enforced at highest
  precedence via `managed-settings.json`, so they can't be re-enabled from inside.
- **Persistent authentication** — `~/.claude` (`CLAUDE_CONFIG_DIR`) lives on a
  named volume, so your login survives rebuilds and `--rm` runs.
- **Firewall enforced on every start** — an `ENTRYPOINT` programs the firewall
  before running your command (fail-closed), so egress is locked whether launched
  via the dev container or a raw `podman`/`docker run`. Requires `NET_ADMIN` +
  `NET_RAW`.

**Podman is recommended over Docker**, on Windows, Linux, and macOS alike:
Podman is daemonless and rootless by default, so there's no long-lived
root-owned socket (Docker's `dockerd` model) whose compromise is equivalent to
host root. Docker works fine too — including its own rootless mode — but that's
an opt-in path rather than the default, first-class one Podman gives you.

### Run it — VS Code dev container

1. Install VS Code + the **Dev Containers** extension and a container engine (Docker or Podman).
2. Open this repo → Command Palette → **Dev Containers: Rebuild Container**.
3. Open a terminal, run `claude`, sign in. Rebuilds keep you signed in.

In the VS Code path the firewall runs via `postStartCommand` (the extension keeps
the container alive with its own command, so the image `ENTRYPOINT` is bypassed —
egress is still enforced).

**Using Podman instead of Docker:** point the extension at Podman in VS Code
settings — no repo change needed:

```jsonc
// settings.json
"dev.containers.dockerPath": "podman"
```

On WSL, run this against your Podman-enabled distro. SELinux relabel (`:Z`) is
generally unnecessary there; add it to the mount only if you hit permission errors.

### Run it — podman / docker directly

```bash
podman run --rm -it \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v claude-code-config:/home/node/.claude \
  -v "$PWD:/workspace:Z" \
  ghcr.io/fyzel/ai-dev-harness:latest
```

The entrypoint programs the firewall, then drops you into bash as `node`. The
named `claude-code-config` volume persists your Claude Code login across runs
(it survives `--rm`). To run **without** the firewall (debugging only), add
`--entrypoint /bin/bash`.

## Building the image

```bash
bin/build-image                 # build local tags from .devcontainer/Dockerfile
bin/build-image --push          # build + push the versioned tag and :latest to GHCR
```

`bin/build-image` requires the Docker CLI regardless of which engine you run the
container with — it shells out to `docker build`/`push`/`login` directly, with
no Podman path. Podman users need `podman-docker`'s Docker-compat shim, or need
to run this script from a machine that has Docker installed.

The version tag is a SemVer string derived from git: an exact `vX.Y.Z` tag on a
clean tree yields `X.Y.Z`; anything else yields `X.Y.Z-dev.<commits-since>.<sha>`
(`.dirty` appended for a dirty tree), with `1.0.0` as the base if no tag exists
yet. A dirty tree skips the `:latest` push.
CI (`build-image.yml`) builds on every PR and pushes the image on every push to
`main` / `dev` or a `v*` tag (not only merges — direct pushes trigger it too).
Pushes to `main` also push a floating `:release` tag; pushes to `dev` push a
floating `:dev` tag instead of `:latest` (`bin/build-image --extra-tag dev
--no-latest`) — `:latest` is reserved for `main`.

Every image CI pushes is signed **keyless** with [cosign](https://docs.sigstore.dev/)
against its registry digest, using the workflow run's GitHub OIDC identity —
no private key is stored or rotated. The signature is logged to the public
[Rekor](https://docs.sigstore.dev/logging/overview/) transparency log and
covers every tag pointing at that digest. Verify a pulled image with:

```bash
cosign verify \
  --certificate-identity-regexp '^https://github\.com/Fyzel/ai-dev-harness/\.github/workflows/build-image\.yml@refs/(heads/(main|dev)|tags/v.*)$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/fyzel/ai-dev-harness:latest
```

Verify the firewall independently of a full container build with
`bin/verify-firewall` (exit code 0 = egress rules enforce correctly).

## AI-assisted pull requests

`bin/create-pr [base-branch]` summarizes your branch's commits + diff with a
local Ollama model and opens a PR via `gh`. Copy `ollama-dev.sample.json` to
`ollama-dev.json` (gitignored) to list your backends; instances are tried in
order with failover.

## Requirements

- Docker or Podman able to grant `NET_ADMIN` + `NET_RAW` (for the in-container
  firewall). Rootless setups that forbid these can't run the firewall — rely on
  host/network controls instead.
- `gh` CLI — for `bin/create-pr` and GHCR push auth.
- A reachable Ollama instance — for `bin/create-pr`.
