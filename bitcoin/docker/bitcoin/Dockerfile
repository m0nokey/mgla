# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.24

FROM alpine:${ALPINE_VERSION} AS builder

ARG ELECTRUM_VERSION=4.8.2
ARG ELECTRUM_ARCHIVE_SHA256=f38cee333c866986cdfb304428fa7487affc429c3853fc80e9822bd420bbc229
ARG THOMASV_FINGERPRINT=6694D8DE7BE8EE5631BED9502BD5824B7F9470E6

ENV AIOHTTP_NO_EXTENSIONS=1 \
    ELECTRUM_ECC_DONT_COMPILE=1 \
    FROZENLIST_NO_EXTENSIONS=1 \
    MULTIDICT_NO_EXTENSIONS=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PROPCACHE_NO_EXTENSIONS=1 \
    YARL_NO_EXTENSIONS=1

RUN apk upgrade --no-cache \
    && apk add --no-cache \
        bash \
        build-base \
        ca-certificates \
        curl \
        gnupg \
        libffi-dev \
        libsecp256k1-dev \
        openssl-dev \
        py3-cryptography \
        py3-pip \
        py3-setuptools \
        py3-virtualenv \
        py3-wheel \
        python3 \
        python3-dev

WORKDIR /tmp/electrum
COPY requirements.lock /tmp/electrum/requirements.lock

RUN set -Eeuo pipefail; \
    archive="Electrum-${ELECTRUM_VERSION}.tar.gz"; \
    base_url="https://download.electrum.org/${ELECTRUM_VERSION}"; \
    curl --fail --location --show-error --silent \
        --proto '=https' --tlsv1.3 --retry 8 --retry-all-errors --retry-delay 2 \
        --connect-timeout 20 --max-time 300 \
        -o "${archive}" "${base_url}/${archive}"; \
    curl --fail --location --show-error --silent \
        --proto '=https' --tlsv1.3 --retry 8 --retry-all-errors --retry-delay 2 \
        --connect-timeout 20 --max-time 120 \
        -o "${archive}.ThomasV.asc" "${base_url}/${archive}.ThomasV.asc"; \
    printf '%s  %s\n' "${ELECTRUM_ARCHIVE_SHA256}" "${archive}" | sha256sum -c -; \
    export GNUPGHOME=/tmp/gnupg; \
    install -d -m 700 "${GNUPGHOME}"; \
    curl --fail --location --show-error --silent \
        --proto '=https' --tlsv1.3 --retry 8 --retry-all-errors --retry-delay 2 \
        --connect-timeout 20 --max-time 120 \
        -o ThomasV.asc https://raw.githubusercontent.com/spesmilo/electrum/master/pubkeys/ThomasV.asc; \
    key_fingerprint="$(gpg --batch --with-colons --import-options show-only --import ThomasV.asc \
        | awk -F: '$1 == "fpr" { print $10; exit }')"; \
    test "${key_fingerprint}" = "${THOMASV_FINGERPRINT}"; \
    gpg --batch --import ThomasV.asc >/dev/null; \
    gpg --batch --verify "${archive}.ThomasV.asc" "${archive}"; \
    tar -xzf "${archive}"; \
    python3 -m venv --system-site-packages /opt/venv; \
    /opt/venv/bin/python -m pip install --no-compile --no-deps --no-build-isolation \
        --require-hashes -r /tmp/electrum/requirements.lock; \
    /opt/venv/bin/python -m pip install --no-compile --no-deps "${PWD}/${archive}"; \
    /opt/venv/bin/electrum --offline --version; \
    site_packages="$(/opt/venv/bin/python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"; \
    rm -rf "${site_packages}/pip" "${site_packages}"/pip-*.dist-info \
        "${site_packages}/setuptools" "${site_packages}"/setuptools-*.dist-info \
        "${site_packages}/wheel" "${site_packages}"/wheel-*.dist-info; \
    rm -f /opt/venv/bin/pip /opt/venv/bin/pip3 /opt/venv/bin/pip3.*; \
    rm -rf /tmp/gnupg /tmp/electrum/ThomasV.asc

FROM alpine:${ALPINE_VERSION}

ARG ELECTRUM_VERSION=4.8.2
ARG ELECTRUM_ARCHIVE_SHA256=f38cee333c866986cdfb304428fa7487affc429c3853fc80e9822bd420bbc229

ENV HOME=/home/electrum \
    ELECTRUMDIR=/home/electrum/.electrum \
    PATH=/opt/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LABEL org.opencontainers.image.title="mgla Bitcoin Electrum CLI" \
      org.opencontainers.image.description="Official Electrum CLI on Alpine with Tor-only transport" \
      org.opencontainers.image.source="https://github.com/spesmilo/electrum" \
      org.opencontainers.image.version="${ELECTRUM_VERSION}" \
      org.opencontainers.image.revision="${ELECTRUM_ARCHIVE_SHA256}"

RUN apk upgrade --no-cache \
    && apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        libgcc \
        libsecp256k1 \
        libstdc++ \
        py3-cryptography \
        python3 \
        qrencode \
        tzdata \
    && addgroup -g 1000 -S electrum \
    && adduser -S -D -H -u 1000 -G electrum -s /sbin/nologin electrum \
    && install -d -m 0700 -o 1000 -g 1000 /home/electrum/.electrum /opt/app /opt/venv

COPY --from=builder /opt/venv /opt/venv
COPY --chmod=0755 docker/bitcoin/entrypoint.sh /usr/local/bin/entrypoint
COPY --chmod=0755 docker/bitcoin/wallet-launcher.sh /opt/app/bitcoin

RUN /opt/venv/bin/electrum --offline --version \
    && /opt/venv/bin/python -c 'import aiohttp, aiorpcx, electrum_ecc, cryptography; print("Electrum runtime imports: OK")' \
    && chmod 0755 /opt/app/bitcoin /usr/local/bin/entrypoint \
    && chown -R 1000:1000 /home/electrum /opt/venv /opt/app

USER 1000:1000
WORKDIR /opt/app
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["sleep", "infinity"]
