# syntax=docker/dockerfile:1.7
ARG ALPINE_VERSION=3.24
FROM alpine:${ALPINE_VERSION} AS runtime-files

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

# Install the stable runtime and explicitly pinned security revisions in one
# layer, then prepare the non-root HAProxy process.
RUN apk add --no-cache \
        ca-certificates \
        haproxy \
        tzdata \
        python3 \
        xxd \
        "zlib>=1.4-r0" \
    && cp /usr/share/zoneinfo/UTC /etc/localtime \
    && printf '%s\n' UTC > /etc/timezone \
    && cp /usr/share/zoneinfo/UTC /tmp/mgla-UTC \
    && apk del tzdata \
    && install -d /usr/share/zoneinfo \
    && mv /tmp/mgla-UTC /usr/share/zoneinfo/UTC \
    && apk add --no-cache \
        --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
        "expat>=2.8.4-r0" \
        "libexpat>=2.8.4-r0" \
        "libssl3>=3.5.8-r0" \
        "libcrypto3>=3.5.8-r0" \
        "sqlite-libs>=3.54.1-r0" \
    && addgroup -g 4242 -S torctl \
    && addgroup haproxy torctl \
    && install -d -m 0755 /usr/local/bin /etc/haproxy \
    && ln -sf /usr/local/bin/tor-control /usr/bin/tor-control

COPY --chmod=0755 tor-control.py /usr/local/bin/tor-control
COPY --chmod=0755 exit-ready-check.sh /usr/local/bin/exit_ready_check
COPY --chmod=0755 render-haproxy-config.sh /usr/local/bin/render-haproxy-config
COPY --chmod=0644 haproxy.cfg.template /etc/haproxy/haproxy.cfg.template
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint-docker.sh

COPY --from=hardened_python_socket /runtime/ /
RUN --mount=type=bind,from=shared,source=runtime,target=/run/python-security \
    /bin/sh /run/python-security/patch-python.sh

COPY --from=hardened_busybox /busybox /bin/busybox
RUN --mount=type=bind,from=shared,source=runtime,target=/run/runtime-config \
    /bin/sh /run/runtime-config/prune-busybox-links.sh

FROM alpine:${ALPINE_VERSION} AS assemble
RUN apk add --no-cache lddtreepax
COPY --from=runtime-files / /source/
RUN --mount=type=bind,from=shared,source=runtime,target=/run/runtime-config \
    python3 /run/runtime-config/stage-runtime.py haproxy

FROM scratch
COPY --from=assemble /runtime/ /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC
USER haproxy:haproxy
ENTRYPOINT ["/usr/local/bin/entrypoint-docker.sh"]
