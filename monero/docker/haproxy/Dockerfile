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
    && addgroup haproxy torctl \
    && install -d -m 0755 /usr/local/bin /etc/haproxy

COPY --chmod=0755 tor-control.py /usr/local/bin/tor-control
COPY --chmod=0755 exit-ready-check.sh /usr/local/bin/exit_ready_check
COPY --chmod=0755 render-haproxy-config.sh /usr/local/bin/render-haproxy-config
COPY --chmod=0644 haproxy.cfg.template /etc/haproxy/haproxy.cfg.template
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint-docker.sh

RUN ln -sf /usr/local/bin/tor-control /usr/bin/tor-control

USER haproxy:haproxy
ENTRYPOINT ["/usr/local/bin/entrypoint-docker.sh"]
