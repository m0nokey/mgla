# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.24
FROM alpine:${ALPINE_VERSION} AS builder

# Use the Alpine package's build configuration and patch set. Disable the
# unused wget applet to remove CVE-2025-60876 without changing the other applets.
ARG APORTS_COMMIT=35f5eb2864e50dd4448758d31f3e2a32f733ab84
RUN apk add --no-cache build-base bzip2 ca-certificates curl git linux-headers \
        openssl-dev patch pkgconf utmps-dev utmps-static

WORKDIR /src
RUN set -eux; \
    git init aports; \
    git -C aports remote add origin https://github.com/alpinelinux/aports.git; \
    git -C aports sparse-checkout set main/busybox; \
    git -C aports fetch --depth 1 --filter=blob:none origin "${APORTS_COMMIT}"; \
    git -C aports checkout --detach FETCH_HEAD; \
    test "$(git -C aports rev-parse HEAD)" = "${APORTS_COMMIT}"; \
    cd aports/main/busybox; \
    pkgver="$(sed -n 's/^pkgver=//p' APKBUILD)"; \
    archive="busybox-${pkgver}.tar.bz2"; \
    curl -fsS --retry 3 --retry-all-errors -o "${archive}" "https://busybox.net/downloads/${archive}"; \
    awk -v archive="${archive}" '$2 == archive' APKBUILD | sha512sum -c -; \
    tar -xf "${archive}"; \
    for item in $(awk '/^sha512sums=/ { checksums = 1 } checksums && $2 ~ /[.]patch$/ { print $2 }' APKBUILD); do \
        patch -d "busybox-${pkgver}" -p1 < "${item}"; \
    done; \
    cp busyboxconfig "busybox-${pkgver}/.config"; \
    cd "busybox-${pkgver}"; \
    grep -qx CONFIG_WGET=y .config; \
    sed -i 's/^CONFIG_WGET=y$/# CONFIG_WGET is not set/' .config; \
    make silentoldconfig; \
    make -j2 CONFIG_EXTRA_CFLAGS="$(pkg-config --cflags --static libutmps)" \
        CONFIG_EXTRA_LDLIBS="$(pkg-config --libs --static libutmps)"; \
    install -D -m 0755 busybox /out/busybox; \
    /out/busybox --list > /tmp/applets; \
    grep -qx sh /tmp/applets; \
    ! grep -qx wget /tmp/applets

FROM scratch
COPY --from=builder /out/busybox /busybox
USER 65532:65532
