#!/bin/bash
# Shared parser/validator for FIREWALL_EXTRA_RULES.
#
# Sourced by both init-firewall.sh (to apply the rules inside the container)
# and bin/validate-firewall-env (to check a candidate env file on the host,
# with no container/root/NET_ADMIN needed) — one implementation of the
# format so the two can't drift apart.
#
# firewall_parse_extra_rules <value>
#   On success: prints one "<proto> <host> <port>" line per rule to stdout,
#   returns 0. An empty/unset <value> is valid — no rules, no output.
#   On the first malformed entry: prints "ERROR: ..." to stderr, returns 1.
#   Callers decide whether that failure is fatal.
firewall_parse_extra_rules() {
    local raw="$1"
    [ -z "$raw" ] && return 0

    # `read <<<` stops at the first newline (it's read's record terminator,
    # not just an IFS field char) — so a value with rules spread across
    # lines for readability would silently truncate to just the first line.
    # Normalize newlines to the same ';' delimiter first so both styles work.
    local normalized
    normalized="$(printf '%s' "$raw" | tr '\n' ';')"

    local -a entries
    IFS=';' read -ra entries <<< "$normalized"

    local rule proto host port extra
    for rule in "${entries[@]}"; do
        # Collapse any run of whitespace so "tcp  1.2.3.4   53" still splits into 3 fields.
        rule="$(echo "$rule" | xargs)"
        [ -z "$rule" ] && continue

        IFS=' ' read -r proto host port extra <<< "$rule"
        if [ -z "$proto" ] || [ -z "$host" ] || [ -z "$port" ] || [ -n "$extra" ]; then
            echo "ERROR: malformed FIREWALL_EXTRA_RULES entry: '$rule' (expected '<tcp|udp> <host> <port>')" >&2
            return 1
        fi
        if [ "$proto" != "tcp" ] && [ "$proto" != "udp" ]; then
            echo "ERROR: invalid protocol '$proto' in FIREWALL_EXTRA_RULES entry: '$rule' (must be tcp or udp)" >&2
            return 1
        fi
        if [[ ! "$host" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
            echo "ERROR: invalid host '$host' in FIREWALL_EXTRA_RULES entry: '$rule' (must be an IPv4 address or CIDR — hostnames are not resolved here)" >&2
            return 1
        fi
        if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo "ERROR: invalid port '$port' in FIREWALL_EXTRA_RULES entry: '$rule' (must be 1-65535)" >&2
            return 1
        fi

        echo "$proto $host $port"
    done
}
