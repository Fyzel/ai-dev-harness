# CLAUDE.md

Guidance for Claude Code working in this repository.

## Project

`ai-dev-harness` — a security-hardened container for running Claude Code, plus the
tooling to build, verify, and publish it. The image runs Claude Code as the
non-root `node` user behind a default-deny egress firewall, with blocked
telemetry and persistent auth, and is published to `ghcr.io/fyzel/ai-dev-harness`.

There is no application source package: this repo *is* the harness. The
"product" is the container image and the POSIX shell tooling around it.

## Layout

| Path | Role |
|------|------|
| `.devcontainer/Dockerfile` | `node:22` base + dev tooling, `iptables`/`ipset`, Claude Code install, firewall + managed-settings wiring, entrypoint. |
| `.devcontainer/init-firewall.sh` | Programs iptables/ipset: default-DROP egress, ipset allowlist, DNS only to the container's `resolv.conf` nameservers, host gateway `/32`, IPv6 lockdown. Self-verifies (telemetry blocked, GitHub reachable) and exits non-zero on failure. |
| `.devcontainer/entrypoint.sh` | Runs the firewall on every container start, then `exec`s the command. Fail-closed. |
| `.devcontainer/devcontainer.json` | Volume mounts, `NET_ADMIN`/`NET_RAW`, env, `postStartCommand` firewall run. |
| `.devcontainer/managed-settings.json` | Telemetry opt-out at highest settings precedence (can't be re-enabled from inside). |
| `.devcontainer/verify-firewall.Dockerfile` | Standalone image to exercise `init-firewall.sh` on Linux from a Windows host. |
| `.devcontainer/README.md` | Authoritative firewall / allowlist / persistent-auth documentation. |
| `bin/build-image` | Build + optionally push the image to GHCR (uses `docker`). |
| `bin/verify-firewall` | Build + run the verify image; exit code = firewall pass/fail. |
| `bin/create-pr` | Generate a PR title/body via a local Ollama model, open the PR with `gh`. |
| `.github/workflows/build-image.yml` | Build on PRs, push on `main` / tags. Third-party actions SHA-pinned. |
| `.github/workflows/lint-actions.yml` | `actionlint` (digest-pinned image) on workflow changes. |
| `.github/dependabot.yml` | Weekly `github-actions` updates (bumps SHA pins + version comments). |
| `ollama-dev.sample.json` | Sample Ollama backend list for `bin/create-pr` (copy to gitignored `ollama-dev.json`). |

## Build / verify / run

- **Build image:** `bin/build-image [--push]` — needs Docker; `--push` needs `gh`
  with `write:packages`.
- **Verify firewall:** `bin/verify-firewall` — needs Docker; runs on a
  user-defined network so Docker's `127.0.0.11` resolver exists.
- **Run:** VS Code *Rebuild Container*, or `podman`/`docker run` the GHCR image
  with `--cap-add=NET_ADMIN --cap-add=NET_RAW`. See `README.md`.
  - VS Code Dev Containers works with either engine; for Podman set
    `"dev.containers.dockerPath": "podman"` in VS Code settings (no repo change).
  - Firewall enforcement differs by path: VS Code overrides the image command, so
    the firewall runs via `postStartCommand`; a raw `docker`/`podman run` runs it
    via the image `ENTRYPOINT`. Keep both paths working when editing either.

## Conventions

- Scripts are POSIX `sh`, except `init-firewall.sh` / `entrypoint.sh` which are
  bash. `*.sh` is pinned to LF via `.gitattributes` — a CRLF checkout breaks the
  Linux shebang.
- GitHub Actions are pinned to full commit SHAs with a trailing `# vX.Y.Z`
  comment; Dependabot bumps both together. Keep any new `uses:` SHA-pinned. The
  `actionlint` container in `lint-actions.yml` is pinned by image **digest**.
- Firewall allowlist: add hostnames to the `for domain in …` loop in
  `init-firewall.sh`. CDN-fronted hosts (Debian mirrors, `downloads.claude.ai`)
  pin the IPs resolved at start — re-run the script if their IPs rotate.
- Telemetry endpoints stay **off** the allowlist by design — do not add them.

## Notes

- The real Ollama config `ollama-dev.json` is gitignored; only the sample is tracked.
- The `.gitignore` base is the standard Python template — keep `.venv/`,
  `__pycache__/`, build artifacts, and IDE files out of commits.
