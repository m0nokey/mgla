# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.24

FROM debian:trixie-slim AS builder
ARG TARGETARCH
ARG MONERO_VERSION=v0.18.5.1
ARG MONERO_COMMIT=4f92268d7c16741cfb41e5bbe2aa46cc260a9ea5
ARG BUILD_JOBS=2

# Keep the GCC major version used by the existing pinned Monero build.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        automake autotools-dev bzip2 ca-certificates cmake curl g++-13 \
        gcc-13 git gperf libc6-dev libtool make patch pkg-config python3 xz-utils \
    && ln -s /usr/bin/gcc-13 /usr/local/bin/gcc \
    && ln -s /usr/bin/g++-13 /usr/local/bin/g++ \
    && ln -s /usr/bin/gcc-13 /usr/local/bin/cc \
    && ln -s /usr/bin/g++-13 /usr/local/bin/c++ \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src/monero
RUN git clone --recursive --depth 1 --shallow-submodules --branch "${MONERO_VERSION}" \
        https://github.com/monero-project/monero.git . \
    && test "$(git rev-parse HEAD)" = "${MONERO_COMMIT}"

# Boost 1.69 treats PTHREAD_STACK_MIN as a preprocessor constant.
# Apply boostorg/thread#297 during the depends preprocessing step.
RUN python3 - <<'PYTHON'
from pathlib import Path

recipe = Path("contrib/depends/packages/boost.mk")
marker = "define $(package)_preprocess_cmds\n"
source = recipe.read_text()
assert source.count(marker) == 1
fix = (
    '  sed -i "s/^#if PTHREAD_STACK_MIN > 0/#ifdef PTHREAD_STACK_MIN/" '
    'boost/thread/pthread/thread_data.hpp &&' + chr(92) + "\n"
)
recipe.write_text(source.replace(marker, marker + fix))

packages = Path("contrib/depends/packages/packages.mk")
source = packages.read_text()
for old, new in (
    ("hardware_packages := hidapi protobuf libusb", "hardware_packages :="),
    ("hardware_native_packages := native_protobuf", "hardware_native_packages :="),
    ("linux_packages = eudev ncurses readline sodium $(hardware_packages)",
     "linux_packages = ncurses readline sodium"),
):
    assert source.count(old) == 1
    source = source.replace(old, new)
packages.write_text(source)
PYTHON

# Use Monero's pinned static dependency builds for the selected Linux target.
# GITIAN=1 skips the optional legacy ccache build.
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) host=x86_64-linux-gnu ;; \
        arm64) \
            host=aarch64-linux-gnu; \
            ln -s /usr/bin/gcc-13 "/usr/local/bin/${host}-gcc"; \
            ln -s /usr/bin/g++-13 "/usr/local/bin/${host}-g++"; \
            ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    make -C contrib/depends HOST="${host}" GITIAN=1 -j"${BUILD_JOBS}" || { \
        status=$?; \
        find contrib/depends/work/build -name config.log -exec cat {} +; \
        exit "${status}"; \
    }; \
    cmake -S . -B build/release \
        -D CMAKE_TOOLCHAIN_FILE="/src/monero/contrib/depends/${host}/share/toolchain.cmake" \
        -D CMAKE_EXE_LINKER_FLAGS=-static \
        -D BUILD_TESTS=OFF \
        -D BUILD_DOCUMENTATION=OFF \
        -D BUILD_DEBUG_UTILITIES=OFF \
        -D USE_DEVICE_TREZOR=OFF \
        -D CMAKE_DISABLE_FIND_PACKAGE_HIDAPI=ON \
        -D CMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -D STACK_TRACE=OFF; \
    if grep -Eq 'device_ledger[.]cpp|device_io_hid[.]cpp|/device_trezor/trezor/' build/release/compile_commands.json; then \
        echo "Hardware wallet code is still enabled" >&2; exit 1; \
    fi; \
    cmake --build build/release --target simplewallet --parallel "${BUILD_JOBS}"; \
    wallet=build/release/bin/monero-wallet-cli; \
    strip --strip-unneeded "${wallet}"; \
    readelf -lW "${wallet}" > /tmp/wallet-program-headers; \
    readelf -dW "${wallet}" > /tmp/wallet-dynamic-section; \
    if grep -qw INTERP /tmp/wallet-program-headers \
        || grep -qw NEEDED /tmp/wallet-dynamic-section; then \
        echo "Expected a statically linked wallet binary" >&2; exit 1; \
    fi

FROM alpine:${ALPINE_VERSION} AS runtime-files

# Shell tools support the existing launcher, curl handles SOCKS requests,
# and the vault needs musl, OpenSSL, libsodium, and libgcc at runtime.
RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        libgcc \
        libsodium \
        libssl3 \
        libcrypto3 \
        tzdata \
    && cp /usr/share/zoneinfo/UTC /etc/localtime \
    && printf '%s\n' UTC > /etc/timezone \
    && cp /usr/share/zoneinfo/UTC /tmp/mgla-UTC \
    && apk del tzdata \
    && install -d /usr/share/zoneinfo \
    && mv /tmp/mgla-UTC /usr/share/zoneinfo/UTC \
    && command -v stty \
    && apk add --no-cache \
        --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
        "expat>=2.8.4-r0" \
        "libexpat>=2.8.4-r0" \
        "libssl3>=3.5.8-r0" \
        "libcrypto3>=3.5.8-r0" \
        "nghttp2-libs>=1.70.0-r0" \
    && addgroup -g 1000 -S user \
    && adduser -S -D -H -u 1000 -G user -s /sbin/nologin user \
    && install -d -m 0755 -o root -g root /opt/app /opt/monero \
    && install -d -m 0700 -o 1000 -g 1000 /monero/wallets /monero/vault-store /tmp/home

COPY --from=builder /src/monero/build/release/bin/monero-wallet-cli /opt/monero/monero-wallet-cli
COPY --from=vault /mgla-vault /opt/monero/mgla-vault
COPY --chmod=0755 --from=shared vault/launcher.sh /opt/monero/vault-launcher.sh
COPY --chmod=0755 --from=shared vault/smoke-test.sh /opt/monero/vault-smoke-test
COPY wallet-launcher.sh /opt/app/monero

RUN chmod 0755 /opt/app/monero /opt/monero/monero-wallet-cli /opt/monero/mgla-vault \
    && ln -s /opt/monero/monero-wallet-cli /usr/local/bin/monero-wallet-cli \
    && /opt/monero/monero-wallet-cli --version \
    && ldd /opt/monero/mgla-vault \
    && if ldd /opt/monero/mgla-vault | grep -q 'not found'; then exit 1; fi

COPY --from=hardened_busybox /busybox /bin/busybox
RUN --mount=type=bind,from=shared,source=runtime,target=/run/runtime-config \
    /bin/sh /run/runtime-config/prune-busybox-links.sh

FROM alpine:${ALPINE_VERSION} AS assemble
RUN apk add --no-cache lddtreepax
COPY --from=runtime-files / /source/
RUN --mount=type=bind,from=shared,source=runtime,target=/run/runtime-config \
    python3 /run/runtime-config/stage-runtime.py monero

FROM scratch
COPY --from=assemble /runtime/ /

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

USER 1000:1000
WORKDIR /opt/app
ENTRYPOINT ["sleep", "infinity"]
