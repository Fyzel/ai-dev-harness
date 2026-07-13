#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# 3. IPv6 lockdown.
# The allowlist below is IPv4-only (ipset hash:net + A-record resolution). If the
# container has IPv6 connectivity, outbound v6 would bypass egress controls
# entirely, so default-deny ALL IPv6 and permit only loopback. This must happen
# before any network I/O so no v6 exfil window exists.
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -F
    ip6tables -X 2>/dev/null || true
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
    ip6tables -A INPUT  -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    echo "IPv6 egress locked down (default-deny, loopback only)"
else
    echo "ERROR: ip6tables not found; refusing to start with unrestricted IPv6 egress" >&2
    exit 1
fi

# 4. Enforce IPv4 default-deny FIRST, before any network I/O.
# Setting the DROP policy up front closes the TOCTOU window: without it, the
# OUTPUT chain would stay ACCEPT while we fetch GitHub ranges and resolve
# domains, letting a process exfiltrate before the firewall is live. All
# bootstrap egress below (dig, curl) instead rides the allowlist rules we install
# now; the allowed-domains ipset is populated incrementally and matched
# dynamically, so hosts become reachable only as they are added.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Baseline allows required for bootstrap.
# Loopback (covers Docker's embedded DNS resolver at 127.0.0.11).
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
# Return traffic for connections we initiate.
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Outbound DNS ONLY to the resolver(s) this container was actually assigned,
# never the whole internet — a broad --dport 53 ACCEPT is itself an egress hole.
# Parse the nameserver(s) from /etc/resolv.conf so this works across runtimes
# instead of hardcoding one address:
#   - Docker:  127.0.0.11            (embedded resolver, DNAT'd to dockerd)
#   - Podman:  e.g. 10.0.2.3         (pasta/netavark) + WSL host 10.255.255.254
resolvers=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf)
if [ -z "$resolvers" ]; then
    echo "ERROR: no nameserver found in /etc/resolv.conf" >&2
    exit 1
fi
while read -r ns; do
    # IPv4 only; the IPv6 stack is default-deny above.
    if [[ ! "$ns" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "Skipping non-IPv4 nameserver: $ns"
        continue
    fi
    echo "Allowing DNS to resolver $ns"
    iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
done < <(echo "$resolvers")
# SSH is intentionally NOT globally allowed: a blanket --dport 22 ACCEPT permits
# outbound SSH to any host, bypassing the allowlist. GitHub's SSH endpoints are
# already covered by the GitHub IP ranges added to the ipset below.

# Create ipset with CIDR support, then install the allowlist-match rule NOW so it
# is in force for the whole bootstrap. The rule matches the set dynamically, so
# entries added later take effect immediately.
ipset create allowed-domains hash:net
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Bootstrap: resolve api.github.com and add it to the allowlist BEFORE curling it,
# so even the first fetch goes through default-deny rather than around it.
echo "Resolving api.github.com for bootstrap..."
bootstrap_ips=$(dig +noall +answer A "api.github.com" | awk '$4 == "A" {print $5}')
if [ -z "$bootstrap_ips" ]; then
    echo "ERROR: Failed to resolve api.github.com"
    exit 1
fi
while read -r ip; do
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "ERROR: Invalid IP from DNS for api.github.com: $ip"
        exit 1
    fi
    echo "Adding bootstrap $ip for api.github.com"
    ipset add allowed-domains "$ip" -exist
done < <(echo "$bootstrap_ips")

# Fetch GitHub meta information and aggregate + add their IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
# GitHub's /meta includes IPv6 CIDRs (e.g. 2620:.../44). This allowlist is
# IPv4-only (ipset hash:net + default-deny IPv6 above), so drop any range that
# isn't a bare IPv4 CIDR BEFORE aggregating — otherwise the validation below
# rejects the v6 entries and exits, blocking devcontainer startup.
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add allowed-domains "$cidr" -exist
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$' | aggregate -q)

# Resolve and add other allowed domains.
#
# EGRESS ALLOWLIST — intentionally excludes optional telemetry / error-reporting
# services. The following domains are DELIBERATELY OMITTED so outbound telemetry
# is blocked at the network layer (in addition to the DISABLE_* env vars):
#     sentry.io                (Claude Code error reporting)
#     statsig.anthropic.com    (Claude Code metrics)
#     statsig.com              (Claude Code metrics)
#
# Only essential domains are allowed:
#     registry.npmjs.org           - npm package installs
#     api.anthropic.com            - Claude API + WebFetch domain safety check
#     claude.ai                    - claude.ai account authentication + install script
#     downloads.claude.ai          - Claude Code self-updater (release binaries + keys)
#     platform.claude.com          - Anthropic Console account authentication
#     marketplace.visualstudio.com - VS Code extension marketplace
#     vscode.blob.core.windows.net - VS Code extension downloads
#     update.code.visualstudio.com - VS Code server bootstrap
#     deb.debian.org               - Debian apt packages (runtime `apt-get install`)
#     security.debian.org          - Debian apt security updates
#     tuf-repo-cdn.sigstore.dev    - Sigstore TUF root of trust, for `cosign verify`
#                                     (Fulcio/Rekor/CT keys; all content is itself
#                                     signed and verified by the TUF client)
#
# CDN CAVEAT: deb.debian.org / security.debian.org are Fastly-fronted CDNs whose
# A records rotate across many IPs. This script resolves them ONCE at firewall
# init and pins only those IPs. A later `apt-get` may be routed to a CDN IP not
# in the set and fail; re-run this script (re-resolves) to refresh. This is the
# trade-off for allowing runtime apt while keeping default-deny egress.
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "claude.ai" \
    "downloads.claude.ai" \
    "platform.claude.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com" \
    "deb.debian.org" \
    "security.debian.org" \
    "tuf-repo-cdn.sigstore.dev"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add allowed-domains "$ip" -exist
    done < <(echo "$ips")
done

# Allow ONLY the default gateway host (the Docker bridge gateway = the host's
# address on this network), not the whole /24. A blanket /24 both directions
# would also reach sibling containers and other host services on the subnet,
# enabling lateral movement / an egress side-channel. Scoping to the single
# gateway /32 keeps host reachability (e.g. the VS Code server) while denying
# neighbors.
# Parse the gateway from `ip -4 route` with awk (grab the token after "via"),
# not `cut -d" " -f3` — route output has variable spacing, so a fixed field
# index can land on an empty field and mis-detect (or fail to detect) the host.
HOST_IP=$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "via") print $(i + 1)}' | head -n1)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host gateway IP"
    exit 1
fi
if [[ ! "$HOST_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "ERROR: Invalid host gateway IP: $HOST_IP"
    exit 1
fi
echo "Host gateway detected as: $HOST_IP"
iptables -A INPUT  -s "$HOST_IP" -j ACCEPT
iptables -A OUTPUT -d "$HOST_IP" -j ACCEPT

# Explicitly REJECT any remaining outbound traffic for immediate feedback.
# (The DROP policy already denies it; REJECT just fails fast instead of hanging.)
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
# --connect-timeout only bounds the TCP/TLS handshake; a host that accepts the
# connection but stalls mid-response would otherwise hang curl (and this
# script's caller, the ENTRYPOINT/postStartCommand) indefinitely. --max-time
# bounds the whole request so a stuck check fails fast instead of hanging
# devcontainer startup.
if curl --connect-timeout 5 --max-time 10 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# google.com is NOT on the allowlist, so egress to it must be denied.
if curl --connect-timeout 5 --max-time 10 https://google.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://google.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://google.com as expected"
fi

# Verify GitHub API access
if ! curl --connect-timeout 5 --max-time 10 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi

# Verify Sigstore TUF reachability, so `cosign verify` can refresh its trust root.
if ! curl --connect-timeout 5 --max-time 10 https://tuf-repo-cdn.sigstore.dev >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://tuf-repo-cdn.sigstore.dev"
    exit 1
else
    echo "Firewall verification passed - able to reach https://tuf-repo-cdn.sigstore.dev as expected"
fi

# Verify telemetry endpoints are BLOCKED (this is the point of this variant).
for blocked in "sentry.io" "statsig.anthropic.com"; do
    if curl --connect-timeout 5 --max-time 10 "https://${blocked}" >/dev/null 2>&1; then
        echo "ERROR: Firewall verification failed - telemetry host ${blocked} is reachable"
        exit 1
    else
        echo "Firewall verification passed - telemetry host ${blocked} is blocked as expected"
    fi
done
