# Issue #49: Add python3.14, python3.14-venv, and trivy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `python3.14`, `python3.14-venv`, and `trivy` to the devcontainer image's default tooling, per [issue #49](https://github.com/Fyzel/ai-dev-harness/issues/49), and open the exact runtime egress this adds.

**Architecture:** `python3.14`/`python3.14-venv` are stock Ubuntu 26.04 (`resolute`) packages — issue #53 already moved the base image to `ubuntu:26.04`, which ships `python3.14` in `main` and `python3.14-venv` in `universe` (both enabled by default), so this is a plain `apt-get install` addition, no deadsnakes/pyenv/source build needed. `trivy` has no Ubuntu apt package, so it's installed from the official Aquasecurity apt repo (GPG-signed, non-snap — matches this repo's existing avoidance of snapd) at build time, pinned to an exact version like the repo's other third-party tool installs (`GIT_DELTA_VERSION`, `NODE_VERSION`). `trivy`'s vulnerability/Java DB and checks-bundle pulls happen at container *runtime* against GHCR, so `init-firewall.sh`'s allowlist needs two new domains for that to work under default-deny egress.

**Tech Stack:** Dockerfile (`apt-get`, GPG-signed apt repo), bash (`init-firewall.sh` iptables/ipset allowlist), Markdown docs.

## Global Constraints

- Base image is `ubuntu:26.04` (issue #53, already merged to `main`/`dev`) — do not reintroduce Debian/`node:22` assumptions.
- Third-party tool versions are pinned exactly via `ARG …_VERSION`, matching the existing `NODE_VERSION`/`GIT_DELTA_VERSION` pattern — no floating `latest`.
- No `snapd`-based installs (conflicts with this repo's non-root, minimal-capability container design — see issue #49's own body).
- Firewall allowlist domains are added to the `for domain in …` loop in `.devcontainer/init-firewall.sh`, following the existing resolve-once-and-pin pattern; CDN-fronted hosts get a one-line caveat in the comment block above the loop.
- `*.sh` files must stay LF (already enforced by `.gitattributes` — no action needed unless creating a new script, which this plan does not).
- Telemetry endpoints (`sentry.io`, `statsig.anthropic.com`, `statsig.com`) stay off the allowlist — not touched by this plan.

---

### Task 1: Add python3.14 and python3.14-venv to the Dockerfile

**Files:**
- Modify: `.devcontainer/Dockerfile:9-29` (main apt-get install layer)
- Modify: `.devcontainer/README.md:183-191` (breaking-change note accuracy)
- Test: manual Docker build + run (no automated test suite in this repo)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `/usr/bin/python3.14` and `python3.14 -m venv` available in the built image. Task 2 does not depend on this, but both land in the same apt-get-install family of changes.

- [ ] **Step 1: Add the two packages to the existing apt-get install list**

Edit `.devcontainer/Dockerfile`, in the first `RUN apt-get update && apt-get install -y --no-install-recommends \` block. Add `python3.14 \` and `python3.14-venv \` after the `jq \` line:

```dockerfile
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
```

- [ ] **Step 2: Build the image locally and verify the packages install**

Run from the repo root:

```bash
bin/build-image --no-latest
```

Expected: build succeeds (exit 0). This produces a local tag like
`ghcr.io/fyzel/ai-dev-harness:<derived-version>` — note the exact tag printed
at the end of the build output for the next step.

- [ ] **Step 3: Verify python3.14 and python3.14-venv work in the built image**

```bash
docker run --rm ghcr.io/fyzel/ai-dev-harness:<derived-version> bash -c \
  "python3.14 --version && python3.14 -m venv /tmp/venv-check && /tmp/venv-check/bin/python3 --version"
```

Expected: prints `Python 3.14.x` twice (system interpreter, then the venv's),
no errors. Note: `/usr/bin/python3` is intentionally **not** created by this
task — `python3.14` alone does not register `update-alternatives` for the
bare `python3` name. This is documented in Step 4, not fixed, since issue
#49 asks for the versioned packages, not the `python3` metapackage.

- [ ] **Step 4: Update the breaking-change note in .devcontainer/README.md for accuracy**

The existing note (around line 183) says `npm install`/`npm ci` with a native
addon fails until a Python is installed manually. That's now partially
stale — a Python interpreter ships by default, but node-gyp's bare `python3`
lookup still won't find it. Edit `.devcontainer/README.md`, appending one
sentence to the existing breaking-change bullet (find the paragraph ending in
`` archive.ubuntu.com`/`security.ubuntu.com`/`ports.ubuntu.com` are allowlisted.``):

```markdown
- **Breaking change:** the base image moved from `node:22` (Debian, via
  `buildpack-deps`) to `ubuntu:26.04`, which no longer implicitly ships a build
  toolchain. `npm install`/`npm ci` on a package with a native addon (node-gyp) will
  fail with `gyp ERR! find Python` until you install one — `node`'s sudoers rule only
  covers `init-firewall.sh`, not general commands, so `sudo apt-get install` won't
  work from inside the container. Instead, from the host: `docker exec --user root
  <container> apt-get install -y build-essential python3` (or `podman exec --user
  root ...`). The firewall allows this either way, since
  `archive.ubuntu.com`/`security.ubuntu.com`/`ports.ubuntu.com` are allowlisted.
  `python3.14`/`python3.14-venv` ship in the image by default (issue #49), but only
  as `python3.14` — node-gyp's bare `python3` lookup still fails until you run
  `docker exec --user root <container> update-alternatives --install /usr/bin/python3
  python3 /usr/bin/python3.14 1`, or set `PYTHON=/usr/bin/python3.14` in the
  environment before `npm install`.
```

- [ ] **Step 5: Commit**

```bash
git add .devcontainer/Dockerfile .devcontainer/README.md
git commit -m "feat: add python3.14 and python3.14-venv to default image (issue #49)"
```

---

### Task 2: Install trivy from the official apt repo, pinned

**Files:**
- Modify: `.devcontainer/Dockerfile:92-98` (add a new `RUN` block after the `git-delta` install, still as `root`, before `USER node`)
- Test: manual Docker build + run

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `trivy` binary on `PATH` in the built image, pinned to `TRIVY_VERSION`. Task 3's firewall changes are required for `trivy image`/`trivy fs` DB pulls to succeed at *container runtime* — `trivy --version` alone does not need them.

- [ ] **Step 1: Add the trivy apt-repo install block**

Edit `.devcontainer/Dockerfile`, inserting this new block immediately after
the existing `git-delta` `RUN` block (after the line
`rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"` and before
`# Set up non-root user` / `USER node`):

```dockerfile
# Install trivy from the official Aquasecurity apt repo (non-snap — snapd
# doesn't run in this container's non-root, minimal-capability setup — see
# issue #49). This adds a new apt trust root (unlike Node/git-delta's
# checksum-pinned downloads) because that's the officially documented
# install path: https://trivy.dev/docs/latest/getting-started/installation/
# Pinned to an exact version via apt, matching NODE_VERSION/GIT_DELTA_VERSION.
# Vulnerability/Java DB pulls happen at container *runtime* against GHCR, not
# at build time — see the ghcr.io / pkg-containers.githubusercontent.com
# entries added to init-firewall.sh's allowlist for that.
ARG TRIVY_VERSION=0.72.0
RUN wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key \
    | gpg --dearmor | tee /usr/share/keyrings/trivy.gpg > /dev/null && \
  echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
    > /etc/apt/sources.list.d/trivy.list && \
  apt-get update && \
  apt-get install -y --no-install-recommends "trivy=${TRIVY_VERSION}" && \
  apt-get clean && rm -rf /var/lib/apt/lists/* && \
  trivy --version
```

- [ ] **Step 2: Build the image locally**

```bash
bin/build-image --no-latest
```

Expected: build succeeds. If it fails with a version-not-found apt error,
`0.72.0` has aged out of the repo's currently-published set — check
`https://trivy.dev/docs/latest/getting-started/installation/` (or
`apt-cache policy trivy` inside an interactive `ubuntu:26.04` container with
the repo added) for the current candidate version and update `TRIVY_VERSION`
accordingly; do not switch to an unpinned `apt-get install -y trivy`.

- [ ] **Step 3: Verify trivy runs in the built image**

```bash
docker run --rm ghcr.io/fyzel/ai-dev-harness:<derived-version> trivy --version
```

Expected: prints `Version: 0.72.0` (or whatever `TRIVY_VERSION` is pinned to).
DB-dependent subcommands (`trivy image`, `trivy fs`) are **not** expected to
work yet in this step — that needs Task 3's firewall allowlist and a running
container (this is a one-off `docker run`, not the full entrypoint/firewall
flow).

- [ ] **Step 4: Commit**

```bash
git add .devcontainer/Dockerfile
git commit -m "feat: install trivy from official apt repo, pinned (issue #49)"
```

---

### Task 3: Allow trivy's runtime GHCR DB pulls through the egress firewall

**Files:**
- Modify: `.devcontainer/init-firewall.sh:148-202` (comment block + `for domain in …` loop)
- Modify: `.devcontainer/init-firewall.sh:252-266` (verification section — add a GHCR reachability check)
- Test: `bin/verify-firewall`

**Interfaces:**
- Consumes: Task 2's `trivy` binary (this task doesn't test `trivy` itself, only that the container's egress reaches GHCR).
- Produces: `ghcr.io` and `pkg-containers.githubusercontent.com` reachable from inside a running container; nothing else in this plan depends on it.

**Context:** per the issue #49 discussion, `trivy`'s default DB registry
order tries `mirror.gcr.io/aquasec` first, falling back to
`ghcr.io/aquasecurity` only on HTTP-level errors (429/5xx) — not on a
connection-level reject. `mirror.gcr.io` sits behind Google's broad serving
IP space, which this repo's resolve-once-and-pin approach can't reliably
pin, so a blocked `mirror.gcr.io` risks `trivy` failing outright instead of
falling through. DB pulls must therefore target GHCR explicitly with
`--db-repository ghcr.io/aquasecurity/trivy-db` (and the equivalent
`--java-db-repository`/checks-bundle flags) when `trivy` is actually run —
that invocation detail is out of scope for this plan (this repo doesn't wrap
`trivy` in any script), so it's a usage note for whoever runs `trivy` inside
the container, not a code change here.

- [ ] **Step 1: Document the two new domains in the comment block**

Edit `.devcontainer/init-firewall.sh`. In the "Only essential domains are
allowed" comment block, add two lines after the `tuf-repo-cdn.sigstore.dev`
entry:

```bash
#     tuf-repo-cdn.sigstore.dev    - Sigstore TUF root of trust, for `cosign verify`
#                                     (Fulcio/Rekor/CT keys; all content is itself
#                                     signed and verified by the TUF client)
#     ghcr.io                      - GHCR manifest/API endpoint, for `trivy`'s
#                                     vulnerability/Java DB + checks-bundle pulls
#                                     at runtime (ghcr.io/aquasecurity/trivy-db etc.)
#     pkg-containers.githubusercontent.com - GHCR blob storage; ghcr.io manifest
#                                     pulls redirect layer/blob fetches here, so
#                                     it's needed alongside ghcr.io, not instead of it
```

Then extend the CDN caveat paragraph immediately below (currently starting
`# CDN CAVEAT: archive.ubuntu.com / security.ubuntu.com / ports.ubuntu.com are`)
to mention the two new hosts:

```bash
# CDN CAVEAT: archive.ubuntu.com / security.ubuntu.com / ports.ubuntu.com are
# geo-DNS mirror redirectors, and tuf-repo-cdn.sigstore.dev / ghcr.io /
# pkg-containers.githubusercontent.com are CDN-fronted (GCP / Azure / Fastly)
# — all with A records that can rotate across many IPs. This script
# resolves them ONCE at firewall init and pins only those IPs. A later
# `apt-get`, `cosign verify`, or `trivy` DB pull may be routed to an IP not
# in the set and fail; re-run this script (re-resolves) to refresh. This is
# the trade-off for allowing runtime apt/cosign/trivy while keeping
# default-deny egress.
```

- [ ] **Step 2: Add the two domains to the resolve-and-pin loop**

In the same file, add both domains to the `for domain in …` list:

```bash
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "claude.ai" \
    "downloads.claude.ai" \
    "platform.claude.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com" \
    "archive.ubuntu.com" \
    "security.ubuntu.com" \
    "ports.ubuntu.com" \
    "tuf-repo-cdn.sigstore.dev" \
    "pkg-containers.githubusercontent.com"; do
```

**Note (post-implementation):** the shipped `init-firewall.sh` does NOT add
`ghcr.io` to this resolve-and-pin loop as drafted above. `ghcr.io` is geo-routed
Azure infrastructure behind a single DNS name — a one-time resolve-and-pin
would still miss most of its IP space. It's pinned instead from GitHub's
meta API `.packages` array (same mechanism as the GitHub Actions runner
IP ranges), which is authoritative rather than a DNS snapshot. Only
`pkg-containers.githubusercontent.com` (GHCR blob storage, genuinely
CDN-fronted) goes through the domain loop above.

- [ ] **Step 3: Add a GHCR reachability check to the verification section**

After the existing Sigstore TUF verification block (ends with
`echo "Firewall verification passed - able to reach https://tuf-repo-cdn.sigstore.dev as expected"` / `fi`), add:

```bash
# Verify GHCR reachability, so `trivy` can pull its vulnerability/Java DB and
# checks bundle at runtime (see the ghcr.io / pkg-containers.githubusercontent.com
# entries added to the allowlist above).
if ! curl --connect-timeout 5 --max-time 10 https://ghcr.io/v2/ >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://ghcr.io/v2/"
    exit 1
else
    echo "Firewall verification passed - able to reach https://ghcr.io/v2/ as expected"
fi
```

Note: an unauthenticated `GET /v2/` against GHCR returns HTTP 401, not a
connection failure — `curl` without `--fail` treats that as success (exit 0),
which is what this check wants: it's testing egress reachability, not
registry auth, matching the existing `tuf-repo-cdn.sigstore.dev` check's
pattern.

- [ ] **Step 4: Run the firewall verification**

```bash
bin/verify-firewall
```

Expected: exits 0, with `Firewall verification passed - able to reach
https://ghcr.io/v2/ as expected` in the output, alongside all the pre-existing
pass lines (`example.com` blocked, `google.com` blocked, `api.github.com`
reachable, `tuf-repo-cdn.sigstore.dev` reachable, telemetry hosts blocked).

- [ ] **Step 5: Commit**

```bash
git add .devcontainer/init-firewall.sh
git commit -m "feat: allowlist ghcr.io for trivy's runtime DB pulls (issue #49)"
```

---

### Task 4: Document the new allowlist entries in .devcontainer/README.md

**Files:**
- Modify: `.devcontainer/README.md:109-127` (egress firewall allowlist table)
- Test: manual read-through (docs-only change)

**Interfaces:**
- Consumes: Task 3's exact domain names (`ghcr.io`, `pkg-containers.githubusercontent.com`).
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Add a table row for the new allowlist entries**

Edit `.devcontainer/README.md`. In the "Allowed" table (the one starting
`| Destination | Why |`), add a row after the `tuf-repo-cdn.sigstore.dev` row
and before the "Host gateway" row:

```markdown
| `tuf-repo-cdn.sigstore.dev`                                                                     | Sigstore TUF root of trust, for `cosign verify` (Fulcio/Rekor/CT keys) |
| `ghcr.io`, `pkg-containers.githubusercontent.com`                                              | GHCR — `trivy` vulnerability/Java DB + checks-bundle pulls at runtime (CDN — see note) |
| Host gateway (`/32`), DNS to `resolv.conf` nameservers, loopback                               | Container plumbing (gateway only — no siblings, no blanket SSH) |
```

- [ ] **Step 2: Read through the rendered table for alignment/typos**

```bash
grep -n "ghcr.io" .devcontainer/README.md
```

Expected: the new row appears once, in the allowlist table, with both
hostnames present.

- [ ] **Step 3: Commit**

```bash
git add .devcontainer/README.md
git commit -m "docs: document ghcr.io allowlist entries for trivy (issue #49)"
```
