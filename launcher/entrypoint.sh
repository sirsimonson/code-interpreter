#!/bin/bash
set -e

# TSI opens guest sockets in this container's network namespace, but the guest
# cannot use Docker's embedded DNS (127.0.0.11) over TSI: UDP resolver queries
# never leave the guest loopback, so a service-name EGRESS_GATEWAY_URL makes
# every artifact upload fail with ConnectionRefused and generated files are
# silently pruned (artifact_delivery_failed). Resolve service names here, in
# the container's network namespace, and hand the guest literal IPs.
#
# The resolver directives are still forwarded below: guest-dns.sh requires a
# nameserver at boot, and the handoff stays correct wherever guest DNS does
# work over TSI.
#
# libkrun places every guest environment entry on the kernel command line,
# which accepts only single-line printable ASCII and is truncated by the guest
# kernel past 2048 bytes. Keep the resolver directives alone, one per field,
# joined by a separator that api/src/guest-dns.sh expands back into lines.
RESOLV_FIELD_SEPARATOR='|'

encode_resolv_conf() {
    local LC_ALL=C
    local line words encoded=''
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [[ ! "$line" =~ ^[[:space:]]*(nameserver|search|domain|options|sortlist)[[:space:]] ]]; then
            continue
        fi
        read -ra words <<< "$line"
        line="${words[*]}"
        if [[ "$line" == *[!' '-'~']* || "$line" == *[\"$RESOLV_FIELD_SEPARATOR]* ]]; then
            echo "ERROR: runner /etc/resolv.conf line cannot cross the kernel command line: $line" >&2
            return 1
        fi
        encoded+="${encoded:+$RESOLV_FIELD_SEPARATOR}$line"
    done
    printf '%s' "$encoded"
}

SANDBOX_RESOLV_CONF="$(encode_resolv_conf < /etc/resolv.conf)"
export SANDBOX_RESOLV_CONF
if [[ "$RESOLV_FIELD_SEPARATOR$SANDBOX_RESOLV_CONF" != *"${RESOLV_FIELD_SEPARATOR}nameserver "[!\#]* ]]; then
    echo 'ERROR: runner /etc/resolv.conf has no nameserver' >&2
    exit 1
fi

resolve_url() {
    local var_name="$1"
    local url="${!var_name}"
    [ -z "$url" ] && return

    local proto="${url%%://*}"
    local rest="${url#*://}"
    local host_port="${rest%%/*}"
    local path="/${rest#*/}"
    [ "$rest" = "$host_port" ] && path=""
    local host port
    case "$host_port" in
        \[*\]:*)
            host="${host_port%%]*}]"
            port="${host_port##*:}"
            ;;
        *)
            host="${host_port%%:*}"
            port="${host_port#*:}"
            [ "$host" = "$port" ] && port=""
            ;;
    esac

    # Literal addresses pass through untouched.
    echo "$host" | grep -qE '^\[[0-9A-Fa-f:.]+\]$' && return
    echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && return

    local ip
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$ip" ]; then
        local new_url="${proto}://${ip}"
        [ -n "$port" ] && new_url="${new_url}:${port}"
        new_url="${new_url}${path}"
        export "$var_name"="$new_url"
        echo "[entrypoint] ${var_name}: ${host} -> ${ip}"
    else
        echo "[entrypoint] WARNING: could not resolve ${host}; passing the hostname through to the guest" >&2
    fi
}

resolve_host_port() {
    local var_name="$1"
    local val="${!var_name}"
    [ -z "$val" ] && return

    local host="${val%%:*}"
    local port="${val#*:}"

    echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && return

    local ip
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$ip" ]; then
        export "$var_name"="${ip}:${port}"
        echo "[entrypoint] ${var_name}: ${host} -> ${ip}"
    else
        echo "[entrypoint] WARNING: could not resolve ${host}; passing the hostname through to the guest" >&2
    fi
}

resolve_url EGRESS_GATEWAY_URL
resolve_url FILE_SERVER_URL
resolve_host_port SANDBOX_FORWARD_TARGET

if [ "${LAUNCHER_FILTER_VSOCK_ENOTCONN:-true}" = "true" ]; then
    # libkrun can emit this benign TSI/vsock teardown line after the guest has
    # already closed its side of the socket. It contains the word "error", so
    # text-based log panels count it as an app failure unless we drop it here.
    exec /usr/local/bin/launcher "$@" \
        2> >(grep --line-buffered -vF 'devices::virtio::vsock::tsi_stream error sending shutdown to socket: ENOTCONN' >&2)
fi

exec /usr/local/bin/launcher "$@"
