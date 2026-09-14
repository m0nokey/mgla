#!/bin/sh
set -eu

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

case "${HAPROXY_SERVER_NAME:-}" in
    exit_a)
        root="/run/tor_a"
        ;;
    exit_b)
        root="/run/tor_b"
        ;;
    *)
        exit 1
        ;;
esac

sock="$root/control.sock"
cookiefile="$root/control.authcookie"

if ! [ -S "$sock" ]; then
    echo "missing control socket: $sock" >&2
    ls -la "$root" >&2 2>/dev/null || true
    exit 1
fi

if ! [ -r "$cookiefile" ]; then
    echo "unreadable auth cookie: $cookiefile" >&2
    ls -la "$root" >&2 2>/dev/null || true
    id >&2 2>/dev/null || true
    exit 1
fi

cookie="$(/usr/bin/xxd -p "$cookiefile" | /usr/bin/tr -d '\n')"
response="$(
    /usr/bin/tor-control "$sock" \
        "AUTHENTICATE $cookie" \
        "getinfo status/bootstrap-phase" ||
        true
)"
if ! echo "$response" | /bin/grep -q 'PROGRESS=100'; then
    echo "Tor is not bootstrapped for $HAPROXY_SERVER_NAME: $response" >&2
    exit 1
fi
