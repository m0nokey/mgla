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
DAEMON_PID=""
DAEMON_LOG="/tmp/mgla-electrum-daemon.log"

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

ci_snapshot() {
    local stage="$1"
    local path

    printf '[debug] wallet-state stage=%s\n' "${stage}"
    printf '[debug] vault_root=%s\n' "${VAULT_ROOT}"
    printf '[debug] wallet_root=%s\n' "${ELECTRUMDIR}"
    printf '[debug] ci_wallet=%s\n' "${CI_WALLET}"
    printf '[debug] ci_vault=%s\n' "${CI_VAULT_FILE}"
    if [[ -e "${VAULT_ROOT}" ]]; then
        stat -c '[debug] root type=%F mode=%a uid=%u gid=%g size=%s inode=%i path=%n' \
            -- "${VAULT_ROOT}" 2>&1 || true
        printf '%s\n' '[debug] vault tree:'
        while IFS= read -r path; do
            stat -c '[debug] entry type=%F mode=%a uid=%u gid=%g size=%s inode=%i path=%n' \
                -- "${path}" 2>&1 || true
        done < <(find "${VAULT_ROOT}" -maxdepth 8 -print 2>&1 | sort)
        printf '%s\n' '[debug] vault filesystem:'
        df -h "${VAULT_ROOT}" 2>&1 || true
    else
        printf '[debug] vault root is absent: %s\n' "${VAULT_ROOT}"
    fi
    if [[ -e "${DAEMON_LOCKFILE}" ]]; then
        stat -c '[debug] daemon lock type=%F mode=%a uid=%u gid=%g size=%s inode=%i path=%n' \
            -- "${DAEMON_LOCKFILE}" 2>&1 || true
        printf '[debug] daemon lock tuple: '
        sed -n '1p' "${DAEMON_LOCKFILE}" 2>&1 || true
    else
        printf '%s\n' '[debug] daemon lockfile is absent'
    fi
    if [[ -e "${DAEMON_SOCKET}" ]]; then
        stat -c '[debug] daemon socket type=%F mode=%a uid=%u gid=%g size=%s inode=%i path=%n' \
            -- "${DAEMON_SOCKET}" 2>&1 || true
    else
        printf '%s\n' '[debug] daemon socket is absent'
    fi
    printf '%s\n' '[debug] processes:'
    ps w 2>&1 || true
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
    if [[ -n "${DAEMON_PID}" ]] && kill -0 "${DAEMON_PID}" 2>/dev/null; then
        return 0
    fi
    [[ -e "${DAEMON_LOCKFILE}" ]]
}

electrum_daemon_ready() {
    [[ -s "${DAEMON_LOCKFILE}" && -S "${DAEMON_SOCKET}" ]] || return 1
    electrum_probe getinfo >/dev/null 2>&1
}

print_daemon_log() {
    if [[ -s "${DAEMON_LOG}" ]]; then
        printf '[debug] Electrum daemon log (%s):\n' "${DAEMON_LOG}"
        sed -n '1,240p' "${DAEMON_LOG}" 2>&1 || true
    else
        printf '[debug] Electrum daemon log is empty: %s\n' "${DAEMON_LOG}"
    fi
}

start_daemon() {
    local attempt

    rm -f -- "${DAEMON_LOG}"
    "${ELECTRUM_BIN}" daemon </dev/null >"${DAEMON_LOG}" 2>&1 &
    DAEMON_PID=$!
    for ((attempt = 1; attempt <= 80; attempt++)); do
        if electrum_daemon_ready; then
            return 0
        fi
        if ! kill -0 "${DAEMON_PID}" 2>/dev/null; then
            wait "${DAEMON_PID}" 2>/dev/null || true
            DAEMON_PID=""
            print_daemon_log
            return 1
        fi
        sleep 0.1
    done
    printf '%s\n' '[error] Electrum daemon did not reach RPC readiness' >&2
    print_daemon_log
    ci_snapshot 'daemon-readiness-timeout'
    return 1
}

stop_daemon() {
    local attempt pid="${DAEMON_PID:-}"

    if [[ -n "${pid}" || -e "${DAEMON_LOCKFILE}" ]]; then
        electrum_probe stop >/dev/null 2>&1 || true
    fi
    for ((attempt = 1; attempt <= 150; attempt++)); do
        if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
            wait "${pid}" 2>/dev/null || true
            DAEMON_PID=""
            pid=""
        fi
        if [[ -z "${pid}" && ! -e "${DAEMON_LOCKFILE}" ]]; then
            vault_remove_runtime_sockets
            rm -f -- "${DAEMON_LOCKFILE}" "${DAEMON_SOCKET}"
            return 0
        fi
        sleep 0.1
    done
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
        kill -TERM "${pid}" 2>/dev/null || true
    fi
    return 1
}

ci_assert_empty() {
    local stage="$1"
    local first

    first="$(find "${VAULT_ROOT}" -mindepth 1 -print -quit 2>/dev/null || true)"
    if [[ -n "${first}" ]]; then
        printf '[error] vault root is not empty at %s; first entry=%s\n' "${stage}" "${first}" >&2
        ci_snapshot "${stage}:non-empty"
        return 1
    fi
}

ci_clear_root() {
    local stage="$1"

    ci_snapshot "${stage}:before-clear"
    if ! clear_wallet_root; then
        printf '[error] failed to clear vault root at %s\n' "${stage}" >&2
        ci_snapshot "${stage}:clear-failed"
        return 1
    fi
    if ! ci_assert_empty "${stage}:after-clear"; then
        return 1
    fi
    ci_snapshot "${stage}:after-clear"
}

ci_require_no_runtime_sockets() {
    local socket

    socket="$(find "${VAULT_ROOT}" -type s -print -quit 2>/dev/null || true)"
    if [[ -n "${socket}" ]]; then
        printf '[error] runtime socket remains before vault pack: %s\n' "${socket}" >&2
        ci_snapshot 'runtime-socket-present'
        return 1
    fi
}

run_vault_command() {
    local stage="$1" password="$2" status
    shift 2

    ci_snapshot "${stage}:before"
    if printf '%s\n' "${password}" |
        "${VAULT_BINARY}" --password-fd 0 "$@"; then
        ci_snapshot "${stage}:after"
        return 0
    else
        status=$?
        printf '[error] vault command failed at %s with status %s\n' "${stage}" "${status}" >&2
        ci_snapshot "${stage}:failed"
        return "${status}"
    fi
}
cleanup() {
    local status=$?
    set +e

    if ((status != 0)); then
        ci_snapshot 'cleanup:before-daemon-stop'
    fi
    stop_daemon || true
    if ((status != 0)); then
        ci_snapshot 'cleanup:after-daemon-stop'
        printf '%s\n' '[debug] preserving failed CI wallet root for diagnostics' >&2
    else
        clear_wallet_root || true
        rm -f -- "${CI_VAULT_FILE}"
    fi
    return "${status}"
}

trap cleanup EXIT

ci_vault_password="$(openssl rand -hex 32)"
ci_wallet_password="$(openssl rand -hex 32)"
rm -f -- "${CI_VAULT_FILE}"
ci_clear_root 'initial'
ensure_wallet_root

run_vault_command 'create' "${ci_vault_password}" create \
    "${CI_VAULT_FILE}" "${VAULT_SIZE}" "${VAULT_ROOT}"

ci_clear_root 'before-initial-unpack'
run_vault_command 'initial-unpack' "${ci_vault_password}" unpack \
    "${CI_VAULT_FILE}" "${VAULT_ROOT}"

configure_electrum
ci_snapshot 'after-electrum-config'
if ! electrum_cli --offline -w "${CI_WALLET}" create \
    --password "${ci_wallet_password}" >/dev/null 2>&1; then
    printf '%s\n' '[error] Electrum wallet creation failed' >&2
    ci_snapshot 'wallet-create-failed'
    exit 1
fi
ci_snapshot 'after-wallet-create'

start_daemon
ci_snapshot 'daemon-ready'
if ! stop_daemon; then
    printf '%s\n' '[error] Electrum daemon did not stop cleanly before vault pack' >&2
    ci_snapshot 'daemon-stop-failed'
    exit 1
fi
ci_snapshot 'after-daemon-stop'
ci_require_no_runtime_sockets

run_vault_command 'pack' "${ci_vault_password}" pack \
    "${CI_VAULT_FILE}" "${VAULT_ROOT}"

ci_clear_root 'before-reopen-unpack'
run_vault_command 'reopen-unpack' "${ci_vault_password}" unpack \
    "${CI_VAULT_FILE}" "${VAULT_ROOT}"
ci_snapshot 'after-reopen-unpack'
if [[ ! -s "${CI_WALLET}" ]]; then
    printf '%s\n' '[error] wallet file is missing after vault reopen' >&2
    ci_snapshot 'wallet-missing-after-reopen'
    exit 1
fi
if ! electrum_cli --offline -w "${CI_WALLET}" getseed \
    --password "${ci_wallet_password}" >/dev/null 2>&1; then
    printf '%s\n' '[error] reopened wallet could not be read' >&2
    ci_snapshot 'wallet-read-after-reopen-failed'
    exit 1
fi
printf '%s\n' '[ok] Bitcoin wallet create, close, save, and reopen test passed'
