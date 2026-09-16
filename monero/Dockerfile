# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.24

FROM alpine:${ALPINE_VERSION} AS builder

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

ARG TARGETARCH
ARG MONERO_VERSION=v0.18.5.1
ARG MONERO_COMMIT=4f92268d7c16741cfb41e5bbe2aa46cc260a9ea5

# Follow Alpine's official Monero APKBUILD dependency model. All compiler and
# development packages remain in this disposable stage.
RUN apk add --no-cache \
        boost-dev \
        build-base \
        ca-certificates \
        cargo \
        ccache \
        cmake \
        cppzmq \
        file \
        git \
        hidapi-dev \
        libsodium-dev \
        linux-headers \
        miniupnpc-dev \
        openssl-dev \
        pkgconf \
        rapidjson-dev \
        readline-dev \
        rust \
        samurai \
        tzdata \
        unbound-dev \
        zeromq-dev \
    && cp /usr/share/zoneinfo/UTC /etc/localtime \
    && printf '%s\n' UTC > /etc/timezone \
    && apk add --no-cache \
        --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
        expat=2.8.4-r0 \
        expat-dev=2.8.4-r0 \
        libexpat=2.8.4-r0 \
        openssl=3.5.8-r0 \
        openssl-dev=3.5.8-r0 \
        libssl3=3.5.8-r0 \
        libcrypto3=3.5.8-r0

WORKDIR /src

# Clone the exact release commit, including the submodule revisions recorded by
# that commit. The tag is not accepted unless it resolves to the pinned hash.
RUN set -eux; \
    git clone --recursive --depth 1 --shallow-submodules --branch "${MONERO_VERSION}" \
        https://github.com/monero-project/monero.git /src/monero; \
    test "$(git -C /src/monero rev-parse HEAD)" = "${MONERO_COMMIT}"

ENV CCACHE_DIR=/ccache

# Build the memory-safe userspace vault before the large Monero compilation so
# changes to the wallet launcher do not invalidate this layer.
WORKDIR /src/vault
COPY --from=shared vault/Cargo.toml vault/Cargo.lock ./
COPY --from=shared vault/src ./src
COPY --from=shared vault/build.sh ./build.sh
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    bash ./build.sh

WORKDIR /src/monero

# Alpine's official package builds Monero directly against maintained Alpine
# libraries. Build only simplewallet; daemon, RPC, GUI, tests, and debug tools
# are not requested.
RUN --mount=type=cache,target=/ccache \
    set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) expected_arch="x86-64" ;; \
        arm64) expected_arch="ARM aarch64" ;; \
        *) echo "unsupported Docker architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    cmake -S . -B build/release -G Ninja \
        -D CMAKE_BUILD_TYPE=Release \
        -D CMAKE_C_COMPILER_LAUNCHER=ccache \
        -D CMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -D STATIC=OFF \
        -D BUILD_64=ON \
        -D BUILD_TESTS=OFF \
        -D BUILD_DOCUMENTATION=OFF \
        -D BUILD_DEBUG_UTILITIES=OFF \
        -D USE_DEVICE_TREZOR=OFF \
        -D USE_READLINE=ON \
        -D STACK_TRACE=OFF \
        -D ARCH=default; \
    cmake --build build/release --target simplewallet --parallel "$(nproc)"; \
    strip --strip-unneeded build/release/bin/monero-wallet-cli; \
    test -x build/release/bin/monero-wallet-cli; \
    file build/release/bin/monero-wallet-cli | grep -F "${expected_arch}"; \
    ldd build/release/bin/monero-wallet-cli; \
    if ldd build/release/bin/monero-wallet-cli | grep -q 'not found'; then exit 1; fi; \
    ccache --show-stats

FROM alpine:${ALPINE_VERSION}

ENV HOME=/tmp/home \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

ARG MONERO_VERSION=v0.18.5.1
ARG MONERO_COMMIT=4f92268d7c16741cfb41e5bbe2aa46cc260a9ea5

LABEL org.opencontainers.image.title="mgla Monero wallet" \
      org.opencontainers.image.description="Source-built Monero CLI wallet with an onion-only transport" \
      org.opencontainers.image.source="https://github.com/monero-project/monero" \
      org.opencontainers.image.version="${MONERO_VERSION}" \
      org.opencontainers.image.revision="${MONERO_COMMIT}"

# Keep the final image limited to runtime packages, the pinned security
# revisions, and the directories required by the non-root wallet process.
RUN apk add --no-cache \
        bash \
        boost-chrono \
        boost-filesystem \
        boost-locale \
        boost-program_options \
        boost-serialization \
        boost-thread \
        ca-certificates \
        curl \
        hidapi \
        libgcc \
        libsodium \
        libstdc++ \
        miniupnpc \
        openssl \
        readline \
        tzdata \
        unbound-libs \
        zeromq \
    && cp /usr/share/zoneinfo/UTC /etc/localtime \
    && printf '%s\n' UTC > /etc/timezone \
    && command -v stty \
    && apk add --no-cache \
        --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
        expat=2.8.4-r0 \
        libexpat=2.8.4-r0 \
        openssl=3.5.8-r0 \
        libssl3=3.5.8-r0 \
        libcrypto3=3.5.8-r0 \
        nghttp2-libs=1.70.0-r0 \
    && addgroup -g 1000 -S user \
    && adduser -S -D -H -u 1000 -G user -s /sbin/nologin user \
    && install -d -m 0755 -o root -g root /opt/app /opt/monero \
    && install -d -m 0700 -o 1000 -g 1000 /monero/wallets /monero/vault-store /tmp/home

COPY --from=builder /src/monero/build/release/bin/monero-wallet-cli /src/vault/target/release/mgla-vault /opt/monero/
COPY --chmod=0755 --from=shared vault/launcher.sh /opt/monero/vault-launcher.sh
COPY --chmod=0755 --from=shared vault/smoke-test.sh /opt/monero/vault-smoke-test
COPY wallet-launcher.sh /opt/app/monero

RUN chmod 0755 /opt/app/monero /opt/monero/monero-wallet-cli /opt/monero/mgla-vault \
    && ln -s /opt/monero/monero-wallet-cli /usr/local/bin/monero-wallet-cli \
    && /opt/monero/monero-wallet-cli --version \
    && ldd /opt/monero/mgla-vault \
    && if ldd /opt/monero/mgla-vault | grep -q 'not found'; then exit 1; fi

USER 1000:1000
WORKDIR /opt/app
ENTRYPOINT ["sleep", "infinity"]
