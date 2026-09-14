#!/bin/sh
set -eu

: "${HAPROXY_IP:?HAPROXY_IP is required}"
: "${EXIT_A_IP:?EXIT_A_IP is required}"
: "${EXIT_B_IP:?EXIT_B_IP is required}"

validate_ipv4() {
    printf '%s\n' "$1" |
        awk -F. '
            NF != 4 { exit 1 }
            {
                for (i = 1; i <= 4; i++) {
                    if ($i !~ /^[0-9]+$/ || $i > 255) {
                        exit 1
                    }
                }
            }
        '
}

if ! validate_ipv4 "$HAPROXY_IP" ||
    ! validate_ipv4 "$EXIT_A_IP" ||
    ! validate_ipv4 "$EXIT_B_IP"; then
    echo "HAProxy and exit addresses must be valid IPv4 addresses" >&2
    exit 1
fi

template="${HAPROXY_TEMPLATE:-/etc/haproxy/haproxy.cfg.template}"
config="${HAPROXY_CONFIG:-/tmp/haproxy.cfg}"

umask 077
sed \
    -e "s|@HAPROXY_IP@|$HAPROXY_IP|g" \
    -e "s|@EXIT_A_IP@|$EXIT_A_IP|g" \
    -e "s|@EXIT_B_IP@|$EXIT_B_IP|g" \
    "$template" > "$config"
