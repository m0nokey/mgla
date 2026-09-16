# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.24

FROM alpine:${ALPINE_VERSION} AS builder

RUN apk add --no-cache \
        bash \
        build-base \
        ca-certificates \
        cargo \
        libsodium-dev \
        openssl-dev \
        pkgconf \
        rust

WORKDIR /src/vault
COPY vault/Cargo.toml vault/Cargo.lock ./
COPY vault/src ./src
COPY vault/build.sh ./build.sh

RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    bash ./build.sh

# This is a build-only image. Wallet images copy this one exact artifact into
# their runtime image; the vault never runs as a separate container.
FROM scratch
COPY --from=builder /src/vault/target/release/mgla-vault /mgla-vault
