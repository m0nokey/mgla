#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

if [[ "$(id -u)" == 0 ]]; then
    printf '%s\n' '[error] the Bitcoin wallet state test must run as a non-root user' >&2
    exit 1
fi

ELECTRUM_BIN="/opt/venv/bin/electrum"
ELECTRUMDIR="/home/electrum/.electrum/bitcoin"
WALLETS_DIR="${ELECTRUMDIR}/wallets"
VAULT_ROOT="/home/electrum/.electrum"
VAULT_BINARY="/opt/bitcoin/mgla-vault"
VAULT_STORE="/bitcoin/vault-store"
VAULT_SIZE="${WALLET_VAULT_SIZE:-128M}"
HAPROXY_IP="${HAPROXY_IP:?HAPROXY_IP is required}"
PROXY_CONFIG="socks5:${HAPROXY_IP}:9095"
CI_VAULT_FILE="${VAULT_STORE}/ci-wallet-state.mgla"
CI_WALLET="${WALLETS_DIR}/ci_state_wallet"
DAEMON_LOCKFILE="${ELECTRUMDIR}/daemon"
DAEMON_SOCKET="${ELECTRUMDIR}/daemon_rpc_socket"

# shellcheck source=/opt/bitcoin/vault-launcher.sh
# shellcheck disable=SC1091
source /opt/bitcoin/vault-launcher.sh
vault_root="${VAULT_ROOT}"
vault_root_expected="${VAULT_ROOT}"
wallet_root="${ELECTRUMDIR}"
[[ "${vault_root}" == "${vault_root_expected}" ]]
[[ "${wallet_root}" == "${ELECTRUMDIR}" ]]

electrum_cli() {
    timeout 45 "${ELECTRUM_BIN}" "$@" </dev/null
}

electrum_probe() {
    timeout 8 "${ELECTRUM_BIN}" "$@" </dev/null
}

set_config() {
    electrum_probe --offline setconfig "$1" "$2" >/dev/null 2>&1
}

configure_electrum() {
    install -d -m 0700 "${ELECTRUMDIR}" "${WALLETS_DIR}"
    set_config proxy "${PROXY_CONFIG}"
    set_config enable_proxy true
    set_config auto_connect false
    set_config oneserver true
    set_config noonion false
    set_config network_timeout 20
}

electrum_daemon_running() {
    [[ -e "${DAEMON_LOCKFILE}" ]]
}

stop_daemon() {
    local attempt

    electrum_probe stop >/dev/null 2>&1 || true
    for ((attempt = 1; attempt <= 50; attempt++)); do
        if ! electrum_daemon_running; then
            vault_remove_runtime_sockets
            return 0
        fi
        sleep 0.1
    done
    return 1
}

cleanup() {
    set +e
    stop_daemon || true
    clear_wallet_root || true
    rm -f -- "${CI_VAULT_FILE}"
    set -e
}

trap cleanup EXIT

ci_vault_password="$(openssl rand -hex 32)"
ci_wallet_password="$(openssl rand -hex 32)"
rm -f -- "${CI_VAULT_FILE}"
clear_wallet_root
ensure_wallet_root

printf '%s\n' "${ci_vault_password}" |
    "${VAULT_BINARY}" --password-fd 0 create \
        "${CI_VAULT_FILE}" "${VAULT_SIZE}" "${VAULT_ROOT}"

clear_wallet_root
printf '%s\n' "${ci_vault_password}" |
    "${VAULT_BINARY}" --password-fd 0 unpack \
        "${CI_VAULT_FILE}" "${VAULT_ROOT}"

configure_electrum
electrum_cli --offline -w "${CI_WALLET}" create \
    --password "${ci_wallet_password}" >/dev/null 2>&1

# Start a local Electrum daemon only to create its runtime Unix socket.
# It must be removed before the vault archive is packed.
electrum_probe daemon -d >/dev/null 2>&1 || true
for ((attempt = 1; attempt <= 80; attempt++)); do
    [[ -S "${DAEMON_SOCKET}" ]] && break
    sleep 0.1
done
if [[ ! -S "${DAEMON_SOCKET}" ]]; then
    printf '%s\n' '[error] wallet state test did not create the Electrum runtime socket' >&2
    exit 1
fi

stop_daemon
if [[ -n "$(find "${VAULT_ROOT}" -type s -print -quit 2>/dev/null || true)" ]]; then
    printf '%s\n' '[error] wallet state test found a runtime socket before packing' >&2
    exit 1
fi

printf '%s\n' "${ci_vault_password}" |
    "${VAULT_BINARY}" --password-fd 0 pack \
        "${CI_VAULT_FILE}" "${VAULT_ROOT}"

clear_wallet_root
printf '%s\n' "${ci_vault_password}" |
    "${VAULT_BINARY}" --password-fd 0 unpack \
        "${CI_VAULT_FILE}" "${VAULT_ROOT}"
test -s "${CI_WALLET}"
electrum_cli --offline -w "${CI_WALLET}" getseed \
    --password "${ci_wallet_password}" >/dev/null 2>&1
printf '%s\n' '[ok] Bitcoin wallet create, close, save, and reopen test passed'
