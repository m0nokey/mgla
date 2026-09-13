# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.24

FROM alpine:${ALPINE_VERSION} AS builder

ARG MONERO_VERSION=v0.18.5.1
ARG MONERO_COMMIT=4f92268d7c16741cfb41e5bbe2aa46cc260a9ea5
ARG UNBOUND_VERSION=1.25.1
ARG UNBOUND_SHA256=0fe8b6277b0959cfd17562debac0aa5f71e0b02dc4ffa9c60271c583edab586f

# Build only the CLI wallet. Optional hardware-wallet and documentation
# dependencies stay out of the image on purpose.
RUN apk add --no-cache \
        autoconf \
        automake \
        bash \
        build-base \
        bzip2 \
        ca-certificates \
        cmake \
        coreutils \
        curl \
        file \
        git \
        gperf \
        libgcc-static \
        libstdc++-dev \
        libtool \
        linux-headers \
        ncurses-dev \
        ncurses-static \
        ninja \
        pkgconf \
        python3 \
        readline-dev \
        readline-static \
        xz-dev \
        zlib-dev \
        zlib-static \
        zstd-dev \
        boost-dev \
        boost1.84-static \
        icu-dev \
        icu-static \
        libsodium-dev \
        libsodium-static \
        zeromq-dev \
        libzmq-static

# Keep the fixed Alpine security versions explicit in the source-build stage.
RUN apk add --no-cache \
        --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
        expat-dev=2.8.4-r0 \
        expat-static=2.8.4-r0 \
        openssl-dev=3.5.8-r0 \
        openssl-libs-static=3.5.8-r0

WORKDIR /src

# Monero's CMake build requires libunbound. Build it from a pinned source
# release so the final wallet can be linked without a shared runtime library.
RUN set -eux; \
    curl -fsSL --proto '=https' --tlsv1.3 \
        --retry 10 --retry-all-errors --retry-delay 2 \
        -o unbound.tar.gz \
        "https://www.nlnetlabs.nl/downloads/unbound/unbound-${UNBOUND_VERSION}.tar.gz"; \
    echo "${UNBOUND_SHA256}  unbound.tar.gz" | sha256sum -c -; \
    tar -xzf unbound.tar.gz; \
    cd "unbound-${UNBOUND_VERSION}"; \
    ./configure \
        --disable-shared \
        --enable-static \
        --without-pyunbound \
        --without-pythonmodule \
        --with-libexpat=/usr \
        --with-ssl=/usr \
        --with-libevent=no \
        --disable-flto \
        --with-pthreads \
        --with-libunbound-only \
        --with-pic \
        --prefix=/opt/unbound; \
    make -j"$(nproc)"; \
    make install; \
    test -f /opt/unbound/lib/libunbound.a; \
    cd /src; \
    rm -rf "unbound-${UNBOUND_VERSION}" unbound.tar.gz

# Clone the exact release commit and verify that the requested tag did not
# resolve to a different commit.
RUN set -eux; \
    git clone --recursive --depth 1 --branch "${MONERO_VERSION}" \
        https://github.com/monero-project/monero.git /src/monero; \
    test "$(git -C /src/monero rev-parse HEAD)" = "${MONERO_COMMIT}"

WORKDIR /src/monero

RUN set -eux; \
    cmake -S . -B build/release -G Ninja \
        -D CMAKE_BUILD_TYPE=Release \
        -D CMAKE_C_COMPILER=gcc \
        -D CMAKE_CXX_COMPILER=g++ \
        -D CMAKE_EXE_LINKER_FLAGS=-static \
        -D STATIC=ON \
        -D BUILD_64=ON \
        -D BUILD_TESTS=OFF \
        -D BUILD_DOCUMENTATION=OFF \
        -D BUILD_DEBUG_UTILITIES=OFF \
        -D USE_DEVICE_TREZOR=OFF \
        -D USE_READLINE=ON \
        -D STACK_TRACE=OFF \
        -D ARCH=default \
        -D UNBOUND_ROOT=/opt/unbound \
        -D UNBOUND_INCLUDE_DIR=/opt/unbound/include \
        -D 'UNBOUND_LIBRARIES=/opt/unbound/lib/libunbound.a;/usr/lib/libexpat.a;/usr/lib/libssl.a;/usr/lib/libcrypto.a' \
        -D 'ICU_LIBRARIES=/usr/lib/libicui18n.a;/usr/lib/libicuuc.a;/usr/lib/libicudata.a'; \
    cmake --build build/release --target simplewallet --parallel "$(nproc)"; \
    test -x build/release/bin/monero-wallet-cli; \
    file build/release/bin/monero-wallet-cli; \
    file build/release/bin/monero-wallet-cli | grep -Eq 'statically linked|static-pie'

FROM alpine:${ALPINE_VERSION}

ENV HOME=/tmp/home

ARG MONERO_VERSION=v0.18.5.1
ARG MONERO_COMMIT=4f92268d7c16741cfb41e5bbe2aa46cc260a9ea5

LABEL org.opencontainers.image.title="mgla Monero wallet" \
      org.opencontainers.image.description="Source-built Monero CLI wallet with an onion-only transport" \
      org.opencontainers.image.source="https://github.com/monero-project/monero" \
      org.opencontainers.image.version="${MONERO_VERSION}" \
      org.opencontainers.image.revision="${MONERO_COMMIT}"

# The wallet binary is static. Runtime packages are limited to the launcher,
# TLS trust store, timezone data, and curl used for onion daemon discovery.
RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        openssl \
        tzdata

RUN apk add --no-cache \
        --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
        openssl=3.5.8-r0 \
        libssl3=3.5.8-r0 \
        libcrypto3=3.5.8-r0

RUN addgroup -g 1000 -S user \
    && adduser -S -D -H -u 1000 -G user -s /sbin/nologin user \
    && install -d -m 0755 -o root -g root /opt/app /opt/monero \
    && install -d -m 0700 -o 1000 -g 1000 /monero/wallets /tmp/home

COPY --from=builder /src/monero/build/release/bin/monero-wallet-cli /opt/monero/monero-wallet-cli
COPY wallet-launcher.sh /opt/app/monero

RUN chmod 0755 /opt/app/monero /opt/monero/monero-wallet-cli \
    && ln -s /opt/monero/monero-wallet-cli /usr/local/bin/monero-wallet-cli

USER 1000:1000
WORKDIR /opt/app
ENTRYPOINT ["sleep", "infinity"]
