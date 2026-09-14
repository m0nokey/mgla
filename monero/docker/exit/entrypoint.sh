#!/bin/sh
set -eu

: "${EXIT_IP:?EXIT_IP is required}"
: "${HAPROXY_IP:?HAPROXY_IP is required}"

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

if ! validate_ipv4 "$EXIT_IP" || ! validate_ipv4 "$HAPROXY_IP"; then
    echo "EXIT_IP and HAPROXY_IP must be valid IPv4 addresses" >&2
    exit 1
fi

umask 077
torrc="/run/tor/torrc"
sed \
    -e "s|@EXIT_IP@|$EXIT_IP|g" \
    -e "s|@HAPROXY_IP@|$HAPROXY_IP|g" \
    /etc/tor/torrc.template > "$torrc"

mkdir -p /var/lib/tor/data
chmod 0700 /var/lib/tor/data
chmod 0750 /run/tor 2>/dev/null || true

tor -f "$torrc" &
tor_pid=$!

shutdown() {
    if [ -n "$tor_pid" ]; then
        kill -TERM "$tor_pid" >/dev/null 2>&1 || true
        wait "$tor_pid" >/dev/null 2>&1 || true
    fi
    exit 0
}
trap shutdown TERM INT

_i=1
while [ "$_i" -le 240 ]; do
    kill -0 "$tor_pid" >/dev/null 2>&1 || exit 1

    if [ -S /run/tor/control.sock ] && [ -r /run/tor/control.authcookie ]; then
        chgrp torctl /run/tor/control.sock /run/tor/control.authcookie \
            >/dev/null 2>&1 || true
        chmod 0660 /run/tor/control.sock >/dev/null 2>&1 || true
        chmod 0640 /run/tor/control.authcookie >/dev/null 2>&1 || true

        cookie="$(xxd -p /run/tor/control.authcookie | tr -d '\n')"
        response="$(
            tor-control /run/tor/control.sock \
                "AUTHENTICATE $cookie" \
                "getinfo status/bootstrap-phase" ||
                true
        )"
        if echo "$response" | grep -q 'PROGRESS=100'; then
            break
        fi
    fi

    sleep 1
    _i=$((_i + 1))
done

if ! [ -S /run/tor/control.sock ]; then
    echo "Tor control socket did not appear" >&2
    exit 1
fi

wait "$tor_pid" || true
shutdown
