# syntax=docker/dockerfile:1.7
FROM alpine:3.24

RUN apk add --no-cache \
        ca-certificates \
        haproxy \
        python3 \
        xxd

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
    && addgroup haproxy torctl

RUN install -d -m 0755 /usr/local/bin /etc/haproxy


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

RUN chmod 0755 /usr/local/bin/tor-control \
    && ln -sf /usr/local/bin/tor-control /usr/bin/tor-control

RUN cat > /usr/local/bin/exit_ready_check <<'EOS'
#!/bin/sh
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

case "${HAPROXY_SERVER_NAME:-}" in
  exit_a) root="/run/tor_a" ;;
  exit_b) root="/run/tor_b" ;;
  *) exit 1 ;;
esac

sock="${root}/control.sock"
cookiefile="${root}/control.authcookie"

if ! [ -S "${sock}" ]; then
    echo "missing control socket: ${sock}" >&2
    ls -la "${root}" >&2 2>/dev/null || true
    exit 1
fi

if ! [ -r "${cookiefile}" ]; then
    echo "unreadable auth cookie: ${cookiefile}" >&2
    ls -la "${root}" >&2 2>/dev/null || true
    id >&2 2>/dev/null || true
    exit 1
fi

cookie="$(/usr/bin/xxd -p "${cookiefile}" | /usr/bin/tr -d '\n')"
resp="$(/usr/bin/tor-control "${sock}" "AUTHENTICATE ${cookie}" "getinfo status/bootstrap-phase" || true)"
if ! echo "${resp}" | /bin/grep -q 'PROGRESS=100'; then
    echo "tor not bootstrapped for ${HAPROXY_SERVER_NAME:-unknown}: ${resp}" >&2
    exit 1
fi
exit 0
EOS

RUN chmod 0755 /usr/local/bin/exit_ready_check \
    && set +e; HAPROXY_SERVER_NAME=exit_a /usr/local/bin/exit_ready_check; rc="$?"; set -e; test "$rc" = "1"

RUN cat > /usr/local/bin/render-haproxy-config <<'EOS'
#!/bin/sh
set -eu

config="${HAPROXY_CONFIG:-/tmp/haproxy.cfg}"
cat > "${config}" <<CFG
global
    log stdout format raw local0
    maxconn 4096
    insecure-fork-wanted
    external-check
    external-check preserve-env

defaults
    log global
    mode tcp
    option dontlognull
    retries 3
    timeout connect 5s
    timeout client 60s
    timeout server 60s
    timeout check  10s
    option log-health-checks

frontend socks_proxy
    bind ${HAPROXY_IP}:9095
    default_backend socks_pool

backend socks_pool
    option external-check
    external-check command /usr/local/bin/exit_ready_check
    option redispatch 1
    server exit_a ${EXIT_A_IP}:9095 check inter 10s rise 1 fall 2
    server exit_b ${EXIT_B_IP}:9095 check inter 10s rise 1 fall 2 backup
CFG
EOS

RUN chmod 0755 /usr/local/bin/render-haproxy-config \
    && true

RUN cat > /usr/local/bin/entrypoint-docker.sh <<'EOS'
#!/bin/sh
set -eu
/usr/local/bin/render-haproxy-config
exec haproxy -f "${HAPROXY_CONFIG:-/tmp/haproxy.cfg}" -db
EOS

RUN chmod 0755 /usr/local/bin/entrypoint-docker.sh

USER haproxy:haproxy
ENTRYPOINT ["/usr/local/bin/entrypoint-docker.sh"]
