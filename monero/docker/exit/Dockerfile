# syntax=docker/dockerfile:1.7
FROM alpine:3.24

RUN apk add --no-cache \
        ca-certificates \
        tor \
        nyx \
        xxd \
        procps-ng \
        python3

# Targeted CVE fixes: Alpine v3.24 aarch64 stable can lag; install only the
# fixed expat and OpenSSL packages from the signed Alpine edge repository.
RUN apk add --no-cache \
        --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
        expat=2.8.4-r0 \
        libexpat=2.8.4-r0 \
        openssl=3.5.8-r0 \
        libssl3=3.5.8-r0 \
        libcrypto3=3.5.8-r0

RUN addgroup -g 4242 -S torctl 2>/dev/null || true \
    && addgroup tor torctl \
    && install -d -m 0755 /usr/local/bin /etc/tor \
    && install -d -m 0700 -o tor -g tor /var/lib/tor \
    && install -d -m 0750 -o tor -g torctl /run/tor


RUN cat > /usr/local/bin/tor-control <<'EOS'
#!/usr/bin/env python3
import socket
import sys

if len(sys.argv) < 3:
    print("usage: tor-control SOCKET COMMAND [COMMAND...]", file=sys.stderr)
    sys.exit(2)

sock_path = sys.argv[1]
commands = sys.argv[2:]

payload = "".join(command.rstrip("\r\n") + "\r\n" for command in commands)
payload += "quit\r\n"

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.settimeout(5)
    sock.connect(sock_path)
    sock.sendall(payload.encode("utf-8"))
    chunks = []
    while True:
        try:
            data = sock.recv(4096)
        except socket.timeout:
            break
        if not data:
            break
        chunks.append(data)

sys.stdout.buffer.write(b"".join(chunks))
EOS

RUN chmod 0755 /usr/local/bin/tor-control

RUN cat > /usr/local/bin/healthcheck <<'EOS'
#!/bin/sh
set -eu

[ -S /run/tor/control.sock ] || exit 1
[ -r /run/tor/control.authcookie ] || exit 1

cookie="$(xxd -p /run/tor/control.authcookie | tr -d '\n')"
tor-control /run/tor/control.sock "AUTHENTICATE ${cookie}" "getinfo status/bootstrap-phase" \
    | grep -q 'PROGRESS=100' || exit 1

tor-control /run/tor/control.sock "AUTHENTICATE ${cookie}" "getinfo circuit-status" \
    | grep -q 'BUILT' || exit 1

exit 0
EOS

RUN cat > /usr/local/bin/entrypoint-docker.sh <<'EOS'
#!/bin/sh
set -eu

: "${EXIT_IP:?EXIT_IP is required}"
: "${HAPROXY_IP:?HAPROXY_IP is required}"

mkdir -p /var/lib/tor/data
chmod 0700 /var/lib/tor/data
chmod 0750 /run/tor 2>/dev/null || true

cat > /run/tor/torrc <<TORRC
Log notice stdout
SocksPort ${EXIT_IP}:9095
SocksPolicy accept ${HAPROXY_IP}/32
SocksPolicy reject *
ControlSocket /run/tor/control.sock
ControlSocketsGroupWritable 1
CookieAuthentication 1
CookieAuthFile /run/tor/control.authcookie
CookieAuthFileGroupReadable 1
DataDirectory /var/lib/tor/data
CircuitBuildTimeout 60
NewCircuitPeriod 30
EnforceDistinctSubnets 1
ConnectionPadding 1
ReducedConnectionPadding 0
BandwidthRate 100 KB
BandwidthBurst 150 KB
ConfluxEnabled 0
SafeSocks 1
ClientRejectInternalAddresses 1
DisableDebuggerAttachment 1
ClientUseIPv6 0
TORRC

tor -f /run/tor/torrc &
tor_pid=$!

shutdown() {
    if [ -n "${tor_pid:-}" ]; then
        kill -TERM "${tor_pid}" >/dev/null 2>&1 || true
        wait "${tor_pid}" >/dev/null 2>&1 || true
    fi
    exit 0
}
trap shutdown TERM INT

_i=1
while [ "${_i}" -le 240 ]; do
    kill -0 "${tor_pid}" >/dev/null 2>&1 || exit 1
    if [ -S /run/tor/control.sock ] && [ -r /run/tor/control.authcookie ]; then
        chgrp torctl /run/tor/control.sock /run/tor/control.authcookie >/dev/null 2>&1 || true
        chmod 0660 /run/tor/control.sock >/dev/null 2>&1 || true
        chmod 0640 /run/tor/control.authcookie >/dev/null 2>&1 || true
        cookie="$(xxd -p /run/tor/control.authcookie | tr -d '\n')"
        resp="$(tor-control /run/tor/control.sock "AUTHENTICATE ${cookie}" "getinfo status/bootstrap-phase" || true)"
        echo "${resp}" | grep -q 'PROGRESS=100' && break
    fi
    sleep 1
    _i=$((_i + 1))
done

if ! [ -S /run/tor/control.sock ]; then
    echo "Tor control socket did not appear" >&2
    exit 1
fi

wait "${tor_pid}" || true
shutdown
EOS

RUN chmod 0755 /usr/local/bin/healthcheck /usr/local/bin/entrypoint-docker.sh

USER tor:torctl
ENTRYPOINT ["/usr/local/bin/entrypoint-docker.sh"]
