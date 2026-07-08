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
    echo "WARNING: ip6tables not found; IPv6 egress NOT restricted"
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
# Outbound DNS ONLY to Docker's embedded resolver (127.0.0.11), never the whole
# internet — a broad --dport 53 ACCEPT is itself an egress hole. Docker DNATs
# this to dockerd, which resolves upstream in the host netns.
iptables -A OUTPUT -p udp -d 127.0.0.11 --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp -d 127.0.0.11 --dport 53 -j ACCEPT
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
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add allowed-domains "$cidr" -exist
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

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
#     claude.ai                    - claude.ai account authentication
#     platform.claude.com          - Anthropic Console account authentication
#     marketplace.visualstudio.com - VS Code extension marketplace
#     vscode.blob.core.windows.net - VS Code extension downloads
#     update.code.visualstudio.com - VS Code server bootstrap
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "claude.ai" \
    "platform.claude.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com"; do
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

# Get host IP from default route and allow the host /24 (both directions).
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"
iptables -A INPUT  -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Explicitly REJECT any remaining outbound traffic for immediate feedback.
# (The DROP policy already denies it; REJECT just fails fast instead of hanging.)
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# google.com is NOT on the allowlist, so egress to it must be denied.
if curl --connect-timeout 5 https://google.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://google.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://google.com as expected"
fi

# Verify GitHub API access
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi

# Verify telemetry endpoints are BLOCKED (this is the point of this variant).
for blocked in "sentry.io" "statsig.anthropic.com"; do
    if curl --connect-timeout 5 "https://${blocked}" >/dev/null 2>&1; then
        echo "ERROR: Firewall verification failed - telemetry host ${blocked} is reachable"
        exit 1
    else
        echo "Firewall verification passed - telemetry host ${blocked} is blocked as expected"
    fi
done
