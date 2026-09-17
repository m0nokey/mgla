# syntax=docker/dockerfile:1.7
FROM alpine:3.24

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

# Install the stable runtime and explicitly pinned security revisions in one
# layer, then create the directories required by the non-root Tor process.
RUN apk add --no-cache \
        ca-certificates \
        tzdata \
        tor \
        nyx \
        xxd \
        procps-ng \
        python3 \
    && cp /usr/share/zoneinfo/UTC /etc/localtime \
    && printf '%s\n' UTC > /etc/timezone \
    && apk add --no-cache \
        --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
        busybox=1.38.0-r6 \
        busybox-binsh=1.38.0-r6 \
        ssl_client=1.38.0-r6 \
        expat=2.8.4-r0 \
        libexpat=2.8.4-r0 \
        openssl=3.5.8-r0 \
        libssl3=3.5.8-r0 \
        libcrypto3=3.5.8-r0 \
    && addgroup -g 4242 -S torctl 2>/dev/null || true \
    && addgroup tor torctl \
    && install -d -m 0755 /usr/local/bin /etc/tor \
    && install -d -m 0700 -o tor -g tor /var/lib/tor \
    && install -d -m 0750 -o tor -g torctl /run/tor

COPY --chmod=0755 tor-control.py /usr/local/bin/tor-control
COPY --chmod=0755 healthcheck.sh /usr/local/bin/healthcheck
COPY --chmod=0644 torrc.template /etc/tor/torrc.template
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint-docker.sh

USER tor:torctl
ENTRYPOINT ["/usr/local/bin/entrypoint-docker.sh"]
