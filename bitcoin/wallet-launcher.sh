#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

if [[ "$(id -u)" == 0 ]]; then
    printf '%s\n' '[error] the Bitcoin wallet must run as a non-root user' >&2
    exit 1
fi

ELECTRUM_BIN="/opt/venv/bin/electrum"
WALLET_VIEW_BIN="/opt/app/wallet-view.py"
ELECTRUMDIR="${ELECTRUMDIR:-/home/electrum/.electrum/bitcoin}"
WALLETS_DIR="${ELECTRUMDIR}/wallets"

if [[ "${ELECTRUMDIR}" != "/home/electrum/.electrum/bitcoin" ]]; then
    printf '%s\n' '[error] ELECTRUMDIR must remain the private tmpfs wallet directory' >&2
    exit 1
fi
HAPROXY_IP="${HAPROXY_IP:?HAPROXY_IP is required}"
PROXY_CONFIG="socks5:${HAPROXY_IP}:9095"
SERVER_SOURCE="https://raw.githubusercontent.com/spesmilo/electrum/refs/heads/master/electrum/chains/mainnet/servers.json"
ONION_FALLBACK_SERVER="${ELECTRUM_ONION_FALLBACK_SERVER:-explorerzydxu5ecjrkwceayqybizmpjjznk5izmitf2modhcusuqlid.onion:110:t}"
DEFAULT_SERVER="${ELECTRUM_DEFAULT_SERVER:-electrum.blockstream.info:50002:s}"

SERVER_CANDIDATES=()
discovered_server=""

electrum_ready=0
shutdown_quiet=0
electrum_version_value=""
tty_is_tty=0
electrum_child_pid=""
probe_height=""
readonly MAX_INPUT_LENGTH=512
readonly MAX_BTC_SATS=2100000000000000
readonly MAX_FEE_RATE_MILLISATVB=1000000000
readonly PROBE_ATTEMPTS=10

ipv4_address_valid() {
    local address="${1:-}" octet
    local -a octets=()

    if [[ ! "${address}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    IFS=. read -r -a octets <<< "${address}"
    if ((${#octets[@]} != 4)); then
        return 1
    fi

    for octet in "${octets[@]}"; do
        if ((10#${octet} > 255)); then
            return 1
        fi
    done
}

if [[ ! -x "${ELECTRUM_BIN}" ]]; then
    printf '[error] Electrum binary is missing: %s\n' "${ELECTRUM_BIN}" >&2
    exit 1
fi

if [[ ! -x "${WALLET_VIEW_BIN}" ]]; then
    printf '[error] Bitcoin wallet view helper is missing: %s\n' "${WALLET_VIEW_BIN}" >&2
    exit 1
fi


if ! ipv4_address_valid "${HAPROXY_IP}"; then
    printf '[error] invalid HAPROXY_IP: %s\n' "${HAPROXY_IP}" >&2
    exit 1
fi

if ! command -v timeout >/dev/null 2>&1; then
    printf '%s\n' '[error] timeout is required by the Electrum launcher' >&2
    exit 1
fi

tty_available() {
    [[ "${tty_is_tty}" -eq 1 ]]
}

tty_write() {
    if tty_available; then
        printf '%s' "$1" > /dev/tty
    else
        printf '%s' "$1"
    fi
}

tty_line() {
    if tty_available; then
        printf '%s\n' "$1" > /dev/tty
    else
        printf '%s\n' "$1"
    fi
}

clear_screen() {
    if tty_available; then
        printf '\033[2J\033[H\033[3J' > /dev/tty
    fi
}

screen_header() {
    local title="$1" subtitle="${2:-}"
    clear_screen
    printf '%s\n' "${title}"
    if [[ -n "${subtitle}" ]]; then
        printf '\n%s\n' "${subtitle}"
    fi
    printf '\n'
}

restore_tty() {
    if tty_available && [[ -n "${original_stty:-}" ]]; then
        stty "${original_stty}" < /dev/tty 2>/dev/null || true
    fi
}

electrum_cli() {
    timeout 45 "${ELECTRUM_BIN}" "$@" </dev/null
}

electrum_probe() {
    timeout 8 "${ELECTRUM_BIN}" "$@" </dev/null
}
electrum_version() {
    local version

    if [[ -n "${electrum_version_value}" ]]; then
        printf '%s\n' "${electrum_version_value}"
        return 0
    fi

    version="$(electrum_probe version 2>/dev/null || true)"
    version="$(printf '%s\n' "${version}" | head -n 1)"
    if [[ -n "${version}" ]]; then
        electrum_version_value="${version}"
        printf '%s\n' "${electrum_version_value}"
        return 0
    fi

    version="$("${ELECTRUM_BIN}" --offline version 2>/dev/null | head -n 1 || true)"
    if [[ -n "${version}" ]]; then
        electrum_version_value="${version}"
        printf '%s\n' "${electrum_version_value}"
        return 0
    fi

    version="$(/opt/venv/bin/python -c 'from electrum.version import ELECTRUM_VERSION; print(ELECTRUM_VERSION)' 2>/dev/null | head -n 1 || true)"
    electrum_version_value="${version}"
    printf '%s\n' "${electrum_version_value}"
}


electrum_tty() {
    local status
    if tty_available; then
        "${ELECTRUM_BIN}" "$@" </dev/tty >/dev/tty 2>/dev/tty &
        electrum_child_pid=$!
        set +e
        wait "${electrum_child_pid}"
        status=$?
        set -e
        electrum_child_pid=""
        return "${status}"
    fi
    "${ELECTRUM_BIN}" "$@"
}

electrum_daemon_running() {
    timeout 1 "${ELECTRUM_BIN}" getinfo </dev/null >/dev/null 2>&1
}

remove_electrum_runtime_sockets() {
    vault_remove_runtime_sockets
}

stop_daemon() {
    local attempts

    electrum_probe stop >/dev/null 2>&1 || true
    for ((attempts = 50; attempts > 0; attempts--)); do
        if ! electrum_daemon_running; then
            if ! remove_electrum_runtime_sockets; then
                return 1
            fi
            return 0
        fi
        sleep 0.1
    done
    return 1
}

save_wallet_state() {
    while ! stop_daemon; do
        tty_line '[warn] Electrum is still stopping; waiting before saving the wallet.'
        sleep 1
    done
    vault_save_until_clean
    # Saving stops the Electrum daemon.  Keep the selected server, but make
    # the next wallet operation start the daemon again without rediscovery.
    electrum_ready=0
}

stop_wallet_child() {
    local pid="${electrum_child_pid:-}"
    local attempts

    [[ -n "${pid}" ]] || return 0

    kill -INT "${pid}" 2>/dev/null || true
    for ((attempts = 50; attempts > 0; attempts--)); do
        if ! kill -0 "${pid}" 2>/dev/null; then
            wait "${pid}" 2>/dev/null || true
            electrum_child_pid=""
            return 0
        fi
        sleep 0.1
    done

    kill -TERM "${pid}" 2>/dev/null || true
    for ((attempts = 50; attempts > 0; attempts--)); do
        if ! kill -0 "${pid}" 2>/dev/null; then
            wait "${pid}" 2>/dev/null || true
            electrum_child_pid=""
            return 0
        fi
        sleep 0.1
    done

    if [[ "${shutdown_quiet:-0}" -ne 1 ]]; then
        tty_line '[warn] Electrum is still closing; waiting to preserve wallet state.'
    fi
    wait "${pid}" 2>/dev/null || true
    electrum_child_pid=""
}

on_signal() {
    shutdown_quiet=1
    stop_wallet_child
    exit 130
}

cleanup() {
    local exit_code=$?

    if [[ "${cleanup_done:-0}" -eq 1 ]]; then
        return "${exit_code}"
    fi
    cleanup_done=1
    shutdown_quiet=1
    trap '' INT TERM HUP QUIT

    stop_wallet_child
    if [[ "${vault_loaded:-0}" -eq 1 && "${vault_dirty:-0}" -eq 1 ]]; then
        while ! stop_daemon; do
            :
            sleep 1
        done
        vault_save_until_clean_quiet
    else
        stop_daemon || true
    fi
    if declare -F stop_vault_session >/dev/null 2>&1; then
        stop_vault_session || true
    fi
    if [[ "${vault_loaded:-0}" -eq 0 || "${vault_dirty:-0}" -eq 0 ]] &&
        declare -F clear_wallet_root >/dev/null 2>&1; then
        clear_wallet_root
    fi

    restore_tty
    return "${exit_code}"
}

cleanup_done=0
trap cleanup EXIT
trap on_signal INT TERM HUP QUIT

if [[ -t 0 && -t 1 ]]; then
    if original_stty="$(stty -g < /dev/tty 2>/dev/null)"; then
        tty_is_tty=1
        stty -echoctl < /dev/tty >/dev/null 2>&1 || true
    fi
fi

read_line() {
    local __var="$1" prompt="$2" input=""
    tty_write "${prompt}"
    if tty_available; then
        if ! IFS= read -r input < /dev/tty; then
            return 1
        fi
    else
        if ! IFS= read -r input; then
            return 1
        fi
    fi
    input="${input//$'\r'/}"
    if (( ${#input} > MAX_INPUT_LENGTH )); then
        tty_line '[error] input is too long.'
        return 1
    fi
    if [[ "${input}" == *[[:cntrl:]]* ]]; then
        tty_line '[error] control characters are not allowed.'
        return 1
    fi
    printf -v "${__var}" '%s' "${input}"
}

read_secret() {
    local __var="$1" prompt="$2" value=""
    tty_write "${prompt}"
    if tty_available; then
        stty -echo < /dev/tty 2>/dev/null || true
        if ! IFS= read -r value < /dev/tty; then
            stty echo < /dev/tty 2>/dev/null || true
            tty_line ""
            return 1
        fi
        stty echo < /dev/tty 2>/dev/null || true
        tty_line ""
    else
        if ! IFS= read -r value; then
            return 1
        fi
    fi
    printf -v "${__var}" '%s' "${value}"
}

is_back() {
    [[ "${1:-}" == "b" || "${1:-}" == "B" ]]
}

is_exit() {
    [[ "${1:-}" == "x" || "${1:-}" == "X" ]]
}

exit_app() {
    exit 0
}

read_menu_choice() {
    local __var="$1" value
    if ! read_line value '?: '; then
        return 1
    fi
    if is_exit "${value}"; then
        exit_app
    fi
    if is_back "${value}"; then
        return 2
    fi
    printf -v "${__var}" '%s' "${value}"
}

prompt_value() {
    local __var="$1" title="$2" help="$3" value
    screen_header "${title}" "${help}"
    tty_line 'b. Back'
    tty_line 'x. Exit'
    tty_line ''
    if ! read_line value '?: '; then
        return 1
    fi
    if is_exit "${value}"; then
        exit_app
    fi
    if is_back "${value}"; then
        return 2
    fi
    printf -v "${__var}" '%s' "${value}"
}

pause_screen() {
    local value
    tty_line ''
    tty_line 'Press Enter or Space to return, or x to exit.'
    if read_line value ''; then
        if is_exit "${value}"; then
            exit_app
        fi
    fi
}

show_screen() {
    local renderer="$1" action
    shift
    while true; do
        "${renderer}" "$@"
        tty_line ''
        tty_line 'Press Enter or Space to return.'
        if ! read_line action ''; then
            return 0
        fi
        if is_exit "${action}"; then
            exit_app
        fi
        if is_back "${action}" ||
           [[ -z "${action}" || "${action}" == ' ' ]]; then
            return 0
        fi
    done
}

# The vault lifecycle is shared with the Monero launcher. These adapters keep
# the Bitcoin launcher UI and non-interactive validation paths unchanged.
vault_tty_blank() {
    tty_line ""
}

vault_tty_printf() {
    if tty_available; then
        # shellcheck disable=SC2059
        printf "$@" > /dev/tty
    else
        # shellcheck disable=SC2059
        printf "$@"
    fi
}

vault_read_choice() {
    local __var="$1" prompt="$2" value=""

    if ! read_line value "${prompt}"; then
        return 1
    fi
    printf -v "${__var}" '%s' "${value}"
}

vault_pause_or_enter() {
    pause_screen
}

vault_tty_clear() {
    clear_screen
}

# ---- shared encrypted wallet vault lifecycle ----
# shellcheck source=../shared/vault/launcher.sh
# shellcheck disable=SC1091
source /opt/bitcoin/vault-launcher.sh
vault_configure \
    "/home/electrum/.electrum" \
    "/home/electrum/.electrum" \
    "${ELECTRUMDIR}" \
    "/opt/bitcoin/mgla-vault" \
    "/bitcoin/vault-store" \
    "${WALLET_VAULT_HOST_DIR:-${HOME}/.mgla}" \
    "${WALLET_VAULT_SIZE:-128M}"


json_value() {
    local key="$1"
    awk -v key="\"${key}\"" '
        { data = data $0 " " }
        END {
            position = index(data, key)
            if (!position) exit
            value = substr(data, position + length(key))
            sub(/^[[:space:]]*:[[:space:]]*/, "", value)
            if (substr(value, 1, 1) == "\"") {
                value = substr(value, 2)
                sub(/".*/, "", value)
            } else {
                sub(/[},].*$/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            }
            print value
        }
    '
}

json_number_value() {
    local key="$1"
    awk -v key="\"${key}\"" '
        { data = data $0 " " }
        END {
            position = index(data, key)
            if (!position) exit
            value = substr(data, position + length(key))
            sub(/^[[:space:]]*:[[:space:]]*/, "", value)
            sub(/[},].*$/, "", value)
            gsub(/"/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
        }
    '
}

set_config() {
    local key="$1" value="$2"
    electrum_probe --offline setconfig "${key}" "${value}" >/dev/null 2>&1
}

current_server() {
    electrum_probe getconfig server 2>/dev/null || true
}

configure_electrum() {
    install -d -m 0700 "${ELECTRUMDIR}" "${WALLETS_DIR}"
    if ! set_config proxy "${PROXY_CONFIG}"; then
        printf '%s\n' '[error] could not set the Electrum SOCKS5 proxy' >&2
        return 1
    fi
    set_config enable_proxy true
    set_config auto_connect false
    set_config oneserver true
    set_config noonion false
    set_config network_timeout 20
    set_config use_exchange_rate true
    set_config currency USD
    set_config use_exchange BitPay
    set_config history_rates true
    set_config fiat_address true
    if [[ -n "${discovered_server}" ]] && ! set_config server "${discovered_server}"; then
        printf '%s\n' '[error] could not restore the selected Electrum server' >&2
        return 1
    fi
    vault_mark_dirty
}

wait_for_connection() {
    local info connected attempt
    for ((attempt = 1; attempt <= 25; attempt++)); do
        info="$(electrum_probe getinfo 2>/dev/null || true)"
        connected="$(printf '%s\n' "${info}" | json_value connected)"
        if [[ "${connected}" == "true" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

start_daemon() {
    local info connected
    info="$(electrum_probe getinfo 2>/dev/null || true)"
    connected="$(printf '%s\n' "${info}" | json_value connected)"
    if [[ "${connected}" == "true" ]]; then
        return 0
    fi
    electrum_probe daemon -d >/dev/null 2>&1 || true
    wait_for_connection
}

load_server_candidates() {
    local json candidate

    SERVER_CANDIDATES=()
    json="$(curl -fsS -L --max-time 20 --max-filesize 1048576 \
        --proto '=https' --tlsv1.3 --noproxy '' \
        --proxy "socks5h://${HAPROXY_IP}:9095" \
        "${SERVER_SOURCE}" 2>/dev/null || true)"
    if [[ -z "${json}" ]]; then
        tty_line "[warn] could not fetch the official Electrum server list through Tor."
        return 1
    fi

    while IFS= read -r candidate; do
        if [[ -n "${candidate}" ]]; then
            SERVER_CANDIDATES+=("${candidate}")
        fi
    done < <(
        printf '%s' "${json}" \
            | awk -v RS='}' '
                /"[a-z2-7]+[.]onion"[[:space:]]*:/ &&
                /"s"[[:space:]]*:[[:space:]]*"/ {
                    if (!match($0, /[a-z2-7]+[.]onion/)) {
                        next
                    }
                    host = substr($0, RSTART, RLENGTH)

                    port = $0
                    sub(/.*"s"[[:space:]]*:[[:space:]]*"/, "", port)
                    sub(/".*/, "", port)

                    if (length(host) == 62 &&
                        host ~ /^[a-z2-7]+[.]onion$/ &&
                        port ~ /^[0-9]+$/ &&
                        port >= 1 && port <= 65535) {
                        endpoint = host ":" port ":s"
                        if (!seen[endpoint]++) {
                            print endpoint
                        }
                    }
                }'
    )

    if (( ${#SERVER_CANDIDATES[@]} == 0 )); then
        tty_line "[warn] the official list contains no usable TLS Onion entries."
        return 1
    fi
    return 0
}

probe_server() {
    local server="$1" info connected height attempt
    probe_height=""
    stop_daemon
    set_config server "${server}"
    electrum_probe daemon -d >/dev/null 2>&1 || true

    for ((attempt = 1; attempt <= PROBE_ATTEMPTS; attempt++)); do
        info="$(electrum_probe getinfo 2>/dev/null || true)"
        connected="$(printf '%s\n' "${info}" | json_value connected)"
        height="$(printf '%s\n' "${info}" | json_number_value server_height)"
        if [[ -z "${height}" ]]; then
            height="$(printf '%s\n' "${info}" | json_number_value blockchain_height)"
        fi
        if [[ "${connected}" == "true" && "${height}" =~ ^[0-9]+$ ]]; then
            probe_height="${height}"
            return 0
        fi
        sleep 1
    done
    return 1
}

discover_best_server() {
    local selected_server="" selected_height="" candidate index total scan=0

    screen_header "Electrum onion discovery" "Selecting the first working server through Tor."
    tty_line "Proxy: HAProxy SOCKS5 with remote DNS through ${HAPROXY_IP}:9095"
    tty_line "Source: ${SERVER_SOURCE}"
    tty_line "Loading the current official TLS Onion entries..."
    if load_server_candidates; then
        total="${#SERVER_CANDIDATES[@]}"
        tty_line "TLS candidates: ${total}"
    else
        total=0
        tty_line 'TLS candidates: unavailable'
    fi
    tty_line "Onion fallback: ${ONION_FALLBACK_SERVER}"
    tty_line "Last fallback: ${DEFAULT_SERVER}"
    tty_line ''

    for index in "${!SERVER_CANDIDATES[@]}"; do
        candidate="${SERVER_CANDIDATES[${index}]}"
        scan=$((scan + 1))
        printf '[scan %02d] %s ... ' "${scan}" "${candidate}"
        if probe_server "${candidate}"; then
            printf 'height=%s\n' "${probe_height}"
            selected_server="${candidate}"
            selected_height="${probe_height}"
            break
        fi
        printf '%s\n' 'unavailable'
    done

    if [[ -z "${selected_server}" ]]; then
        tty_line ''
        tty_line 'No TLS Onion server responded; trying the Blockstream Onion Electrum endpoint through Tor.'
        printf '[onion fallback] %s ... ' "${ONION_FALLBACK_SERVER}"
        if probe_server "${ONION_FALLBACK_SERVER}"; then
            printf 'height=%s\n' "${probe_height}"
            selected_server="${ONION_FALLBACK_SERVER}"
            selected_height="${probe_height}"
        else
            printf '%s\n' 'unavailable'
        fi
    fi

    if [[ -z "${selected_server}" ]]; then
        tty_line ''
        tty_line 'The Blockstream Onion endpoint is unavailable; trying the final Electrum fallback through Tor.'
        printf '[fallback] %s ... ' "${DEFAULT_SERVER}"
        if probe_server "${DEFAULT_SERVER}"; then
            printf 'height=%s\n' "${probe_height}"
            selected_server="${DEFAULT_SERVER}"
            selected_height="${probe_height}"
        else
            printf '%s\n' 'unavailable'
        fi
    fi

    if [[ -z "${selected_server}" ]]; then
        printf '%s\n' '[error] no working Electrum server was found' >&2
        return 1
    fi

    discovered_server="${selected_server}"
    stop_daemon
    set_config server "${selected_server}"
    vault_mark_dirty
    if ! start_daemon; then
        printf '[error] selected server did not start: %s\n' "${selected_server}" >&2
        return 1
    fi

    screen_header "Electrum onion discovery" "The first working server was selected through Tor."
    tty_line "Server: ${selected_server}"
    tty_line "Reported height: ${selected_height}"
    tty_line 'Transport: SOCKS5 with remote DNS through HAProxy'
    tty_line ''
    return 0
}

ensure_electrum_ready() {
    # Discover exactly once after the vault is unlocked and before the wallet
    # menu. All wallet operations then reuse the same selected server.
    if [[ "${electrum_ready}" -eq 1 ]]; then
        return 0
    fi

    if [[ -n "${discovered_server}" ]]; then
        if ! start_daemon; then
            printf '[error] selected server did not start: %s\n' "${discovered_server}" >&2
            return 1
        fi
    elif ! discover_best_server; then
        return 1
    fi
    electrum_ready=1
}

wallet_name_valid() {
    local name="$1"
    [[ "${name}" != "." && "${name}" != ".." ]] || return 1
    [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ ]] || return 1
    [[ "${name}" != *'..'* ]] || return 1
    [[ "${name}" != *.tmp && "${name}" != *.tmp.* ]] || return 1
}

btc_amount_to_sats() {
    local value="${1:-}" whole fraction sats
    if [[ ! "${value}" =~ ^([0-9]+)([.]([0-9]{1,8}))?$ ]]; then
        return 1
    fi
    whole="${BASH_REMATCH[1]}"
    fraction="${BASH_REMATCH[3]:-}"
    while [[ "${whole}" == 0* && ${#whole} -gt 1 ]]; do
        whole="${whole:1}"
    done
    while (( ${#fraction} < 8 )); do
        fraction+="0"
    done
    if (( ${#whole} > 8 || 10#${whole} > 21000000 )); then
        return 1
    fi
    sats=$((10#${whole} * 100000000 + 10#${fraction}))
    if (( sats <= 0 || sats > MAX_BTC_SATS )); then
        return 1
    fi
    printf '%s\n' "${sats}"
}

btc_amount_valid() {
    local value="${1:-}"
    if [[ "${value}" == '!' ]]; then
        return 1
    fi
    btc_amount_to_sats "${value}" >/dev/null
}

fee_rate_to_millisatvb() {
    local value="${1:-}" whole fraction scaled
    if [[ ! "${value}" =~ ^([0-9]+)([.]([0-9]{1,3}))?$ ]]; then
        return 1
    fi
    whole="${BASH_REMATCH[1]}"
    fraction="${BASH_REMATCH[3]:-}"
    while [[ "${whole}" == 0* && ${#whole} -gt 1 ]]; do
        whole="${whole:1}"
    done
    while (( ${#fraction} < 3 )); do
        fraction+="0"
    done
    if (( ${#whole} > 7 )); then
        return 1
    fi
    scaled=$((10#${whole} * 1000 + 10#${fraction}))
    if (( scaled <= 0 || scaled > MAX_FEE_RATE_MILLISATVB )); then
        return 1
    fi
    printf '%s\n' "${scaled}"
}

fee_rate_valid() {
    fee_rate_to_millisatvb "${1:-}" >/dev/null
}

set_fee_rate() {
    local variable="$1" value="$2"
    if fee_rate_valid "${value}"; then
        printf -v "${variable}" '%s' "${value}"
    else
        printf -v "${variable}" '%s' 'n/a'
    fi
}

menu_index_valid() {
    local value="${1:-}" maximum="${2:-}"
    [[ "${value}" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
    [[ "${maximum}" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
    (( 10#${value} <= 10#${maximum} ))
}

bitcoin_address_syntax_valid() {
    local address="${1:-}"
    [[ "${address}" =~ ^[A-Za-z0-9]{26,90}$ ]] || return 1
    case "${address}" in
        1*|3*|bc1*|BC1*) return 0 ;;
        *) return 1 ;;
    esac
}

run_input_validation_tests() {
    local value
    local -a valid_amounts=(
        '0.00000001'
        '1'
        '0001.2'
        '21000000'
        '21000000.00000000'
    )
    local -a invalid_amounts=(
        '0'
        '0.00000000'
        '1.123456789'
        '21000000.00000001'
        '21000001'
        '+1'
        '1e2'
        '1 '
    )
    local -a valid_fee_rates=('0.001' '1' '0001.250' '1000000')
    local -a invalid_fee_rates=('0' '0.000' '1.1234' '1000000.001' '+1' '1e2' '1 ')
    local -a valid_addresses=(
        '1BoatSLRHtKNngkdXEeobR76b53LETtpyT'
        '3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy'
        'bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh'
    )
    local -a invalid_addresses=(
        '2J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy'
        'bc1short'
        '1BoatSLRHtKNngkdXEeobR76b53LETtpyT '
    )
    local -a valid_indexes=('1' '10')
    local -a invalid_indexes=('0' '11' '999999999')
    local -a valid_wallet_names=('default_wallet' 'savings-2026.dat' 'A_1')
    local -a invalid_wallet_names=('.' '..' '../wallet' 'foo..bar' 'wallet.tmp' ' wallet')

    for value in "${valid_amounts[@]}"; do
        if ! btc_amount_valid "${value}"; then
            printf '[error] amount validation self-test rejected: %s\n' "${value}" >&2
            return 1
        fi
    done
    for value in "${invalid_amounts[@]}"; do
        if btc_amount_valid "${value}"; then
            printf '[error] amount validation self-test accepted: %s\n' "${value}" >&2
            return 1
        fi
    done
    for value in "${valid_fee_rates[@]}"; do
        if ! fee_rate_valid "${value}"; then
            printf '[error] fee validation self-test rejected: %s\n' "${value}" >&2
            return 1
        fi
    done
    for value in "${invalid_fee_rates[@]}"; do
        if fee_rate_valid "${value}"; then
            printf '[error] fee validation self-test accepted: %s\n' "${value}" >&2
            return 1
        fi
    done
    for value in "${valid_addresses[@]}"; do
        if ! bitcoin_address_syntax_valid "${value}"; then
            printf '[error] address validation self-test rejected: %s\n' "${value}" >&2
            return 1
        fi
    done
    for value in "${invalid_addresses[@]}"; do
        if bitcoin_address_syntax_valid "${value}"; then
            printf '[error] address validation self-test accepted: %s\n' "${value}" >&2
            return 1
        fi
    done
    for value in "${valid_indexes[@]}"; do
        if ! menu_index_valid "${value}" '10'; then
            printf '[error] menu validation self-test rejected: %s\n' "${value}" >&2
            return 1
        fi
    done
    for value in "${invalid_indexes[@]}"; do
        if menu_index_valid "${value}" '10'; then
            printf '[error] menu validation self-test accepted: %s\n' "${value}" >&2
            return 1
        fi
    done
    for value in "${valid_wallet_names[@]}"; do
        if ! wallet_name_valid "${value}"; then
            printf '[error] wallet-name validation self-test rejected: %s\n' "${value}" >&2
            return 1
        fi
    done
    for value in "${invalid_wallet_names[@]}"; do
        if wallet_name_valid "${value}"; then
            printf '[error] wallet-name validation self-test accepted: %s\n' "${value}" >&2
            return 1
        fi
    done
    printf '%s\n' '[ok] strict wallet input validation checks passed'
}

wallet_path_prompt() {
    local __var="$1" name rc
    if prompt_value name 'Wallet name' "Enter a short name (Enter uses 'default_wallet')."; then
        :
    else
        rc=$?
        return "${rc}"
    fi
    name="${name:-default_wallet}"
    if ! wallet_name_valid "${name}"; then
        tty_line 'Invalid wallet name. Use letters, numbers, dots, underscores, or dashes.'
        return 1
    fi
    install -d -m 0700 "${WALLETS_DIR}"
    printf -v "${__var}" '%s/%s' "${WALLETS_DIR}" "${name}"
}

unlock_wallet() {
    local wallet="$1"
    screen_header 'Open wallet' "Wallet: $(basename "${wallet}")"
    tty_line 'Enter the wallet password in Electrum.'
    tty_line 'The password is read by Electrum and is not stored by this launcher.'
    tty_line ''
    vault_mark_dirty
    electrum_tty -w "${wallet}" load_wallet
}
open_created_wallet() {
    local wallet="$1"
    screen_header 'Open wallet' "Wallet: $(basename "${wallet}")"
    tty_line 'The wallet was created. Enter the same wallet password to load it into Electrum.'
    tty_line 'The launcher does not store this password.'
    tty_line ''
    vault_mark_dirty
    electrum_tty -w "${wallet}" load_wallet
}


create_wallet() {
    local wallet seed answer rc wallet_changed=0
    if wallet_path_prompt wallet; then
        :
    else
        rc=$?
        [[ "${rc}" -eq 2 ]] && return 0
        return 0
    fi
    if [[ -e "${wallet}" ]]; then
        screen_header 'Create wallet' 'The requested wallet already exists.'
        tty_line "Wallet: ${wallet}"
        pause_screen
        return 0
    fi

    if ! ensure_electrum_ready; then
        pause_screen
        return 0
    fi
    seed="$(electrum_cli make_seed 2>/dev/null || true)"
    if [[ -z "${seed}" ]]; then
        screen_header 'Create wallet' 'Seed generation failed.'
        pause_screen
        return 0
    fi
    screen_header 'Create wallet' 'Write the seed down offline before continuing.'
    tty_line 'Seed phrase:'
    tty_line "${seed}"
    tty_line ''
    tty_line 'After saving the seed, press Enter to set the wallet password.'
    tty_line 'Press x to exit.'
    if ! read_line answer ''; then
        unset seed
        return 0
    fi
    if is_exit "${answer}"; then
        unset seed
        exit_app
    fi
    unset seed

    screen_header 'Create wallet' 'Electrum will now ask for the seed and wallet password.'
    vault_mark_dirty
    if electrum_tty -w "${wallet}" restore :; then
        wallet_changed=1
        if open_created_wallet "${wallet}"; then
            wallet_menu "${wallet}"
        else
            screen_header 'Create wallet' 'Wallet was created but could not be loaded.'
            tty_line 'It remains in the vault and can be opened from the wallet list.'
            pause_screen
        fi
    else
        # Keep any partial wallet file for recovery; never delete user state
        # automatically after an interrupted or failed Electrum operation.
        wallet_changed=1
        screen_header 'Create wallet' 'Wallet creation failed; any partial wallet data was kept.'
        tty_line 'If a wallet file was created, it remains encrypted in the vault for recovery.'
        pause_screen
    fi
    if [[ "${wallet_changed}" -eq 1 ]]; then
        save_wallet_state
    fi
}

restore_wallet() {
    local wallet rc wallet_changed=0
    if wallet_path_prompt wallet; then
        :
    else
        rc=$?
        [[ "${rc}" -eq 2 ]] && return 0
        return 0
    fi
    if [[ -e "${wallet}" ]]; then
        screen_header 'Restore wallet' 'The requested wallet already exists.'
        tty_line "Wallet: ${wallet}"
        pause_screen
        return 0
    fi
    if ! ensure_electrum_ready; then
        pause_screen
        return 0
    fi
    screen_header 'Restore wallet' 'Enter the existing seed in Electrum.'
    tty_line 'The seed and password are entered directly into Electrum.'
    tty_line ''
    vault_mark_dirty
    if electrum_tty -w "${wallet}" restore :; then
        wallet_changed=1
        if open_created_wallet "${wallet}"; then
            wallet_menu "${wallet}"
        else
            screen_header 'Restore wallet' 'Wallet was restored but could not be loaded.'
            tty_line 'It remains in the vault and can be opened from the wallet list.'
            pause_screen
        fi
    else
        # Keep any partial wallet file for recovery; never delete user state
        # automatically after an interrupted or failed Electrum operation.
        wallet_changed=1
        screen_header 'Restore wallet' 'Wallet restoration failed; any partial wallet data was kept.'
        tty_line 'If a wallet file was created, it remains encrypted in the vault for recovery.'
        pause_screen
    fi
    if [[ "${wallet_changed}" -eq 1 ]]; then
        save_wallet_state
    fi
}

show_wallets() {
    local -a wallets=()
    local wallet name choice rc count index
    while true; do
        screen_header 'Wallets' 'Choose an existing Electrum wallet.'
        wallets=()
        count=0
        while IFS= read -r wallet; do
            name="$(basename "${wallet}")"
            if wallet_name_valid "${name}"; then
                wallets+=("${wallet}")
                count=$((count + 1))
                printf '%2d. %s\n' "${count}" "${name}"
            fi
        done < <(find "${WALLETS_DIR}" -maxdepth 1 -type f -print 2>/dev/null | sort)

        if [[ "${count}" -eq 0 ]]; then
            tty_line 'No wallets found.'
            tty_line 'Create a new wallet or restore one from a seed first.'
            pause_screen
            return 0
        fi

        tty_line ''
        tty_line 'b. Back'
        tty_line 'x. Exit'
        if read_menu_choice choice; then
            :
        else
            rc=$?
            [[ "${rc}" -eq 2 ]] && return 0
            return 0
        fi
        if menu_index_valid "${choice}" "${count}"; then
            index=$((10#${choice} - 1))
            if ! ensure_electrum_ready; then
                pause_screen
            elif unlock_wallet "${wallets[${index}]}"; then
                wallet_menu "${wallets[${index}]}"
                save_wallet_state
            fi
        fi
    done
}

render_wallet_balance() {
    local wallet="$1" balance confirmed unconfirmed unmatured lightning total
    screen_header 'Wallet balance' 'Confirmed and pending balances reported by Electrum.'
    balance="$(electrum_cli -w "${wallet}" getbalance 2>/dev/null || true)"
    confirmed="$(printf '%s\n' "${balance}" | json_number_value confirmed)"
    unconfirmed="$(printf '%s\n' "${balance}" | json_number_value unconfirmed)"
    unmatured="$(printf '%s\n' "${balance}" | json_number_value unmatured)"
    lightning="$(printf '%s\n' "${balance}" | json_number_value lightning)"
    confirmed="${confirmed:-0}"
    unconfirmed="${unconfirmed:-0}"
    unmatured="${unmatured:-0}"
    lightning="${lightning:-0}"
    total="$(awk -v confirmed="${confirmed}" -v unconfirmed="${unconfirmed}" -v unmatured="${unmatured}" -v lightning="${lightning}" 'BEGIN { printf "%.8f", confirmed + unconfirmed + unmatured + lightning }')"
    printf '%-14s %s BTC\n' 'Total:' "${total}"
    printf '%-14s %s BTC\n' 'Confirmed:' "${confirmed}"
    printf '%-14s %s BTC\n' 'Unconfirmed:' "${unconfirmed}"
    if [[ "${unmatured}" != 0 && "${unmatured}" != 0.0 && "${unmatured}" != 0.00000000 ]]; then
        printf '%-14s %s BTC\n' 'Unmatured:' "${unmatured}"
    fi
    if [[ "${lightning}" != 0 && "${lightning}" != 0.0 && "${lightning}" != 0.00000000 ]]; then
        printf '%-14s %s BTC\n' 'Lightning:' "${lightning}"
    fi
}

show_wallet_balance() {
    show_screen render_wallet_balance "$@"
}

render_receive_address() {
    local wallet="$1" address error_file
    screen_header 'Receive BTC' 'Use this address to receive bitcoin.'
    error_file="$(mktemp /tmp/mgla-electrum-address.XXXXXX)"
    address="$(electrum_cli -w "${wallet}" getunusedaddress 2>"${error_file}" || true)"
    if ! bitcoin_address_syntax_valid "${address}"; then
        address="$(electrum_cli -w "${wallet}" createnewaddress 2>"${error_file}" || true)"
    fi
    if ! bitcoin_address_syntax_valid "${address}"; then
        tty_line 'Could not obtain a Bitcoin receiving address.'
        sed -n '1,12p' "${error_file}" 2>/dev/null || true
        rm -f -- "${error_file}"
        return 0
    fi
    rm -f -- "${error_file}"
    tty_line 'Address:'
    tty_line "${address}"
}

show_receive_address() {
    show_screen render_receive_address "$@"
}

render_new_receive_address() {
    local wallet="$1" address error_file
    screen_header 'New receive address' 'Generate a fresh deterministic receiving address.'
    error_file="$(mktemp /tmp/mgla-electrum-address.XXXXXX)"
    address="$(electrum_cli -w "${wallet}" createnewaddress 2>"${error_file}" || true)"
    if ! bitcoin_address_syntax_valid "${address}"; then
        tty_line 'Could not create a new Bitcoin receiving address.'
        sed -n '1,12p' "${error_file}" 2>/dev/null || true
        rm -f -- "${error_file}"
        return 0
    fi
    rm -f -- "${error_file}"
    tty_line 'Address:'
    tty_line "${address}"
}

show_new_receive_address() {
    show_screen render_new_receive_address "$@"
}

render_transaction_history() {
    local wallet="$1" history error_file
    screen_header 'Transaction history' 'On-chain activity reported by Electrum.'
    error_file="$(mktemp /tmp/mgla-electrum-history.XXXXXX)"
    history="$(electrum_cli -w "${wallet}" onchain_history 2>"${error_file}" || true)"
    if [[ -z "${history}" ]]; then
        tty_line 'Could not read the wallet transaction history.'
        sed -n '1,12p' "${error_file}" 2>/dev/null || true
        rm -f -- "${error_file}"
        return 0
    fi
    if ! printf '%s\n' "${history}" | "${WALLET_VIEW_BIN}" history; then
        tty_line 'Electrum returned an unreadable transaction history.'
        sed -n '1,12p' "${error_file}" 2>/dev/null || true
    fi
    rm -f -- "${error_file}"
}

show_transaction_history() {
    show_screen render_transaction_history "$@"
}

render_wallet_addresses() {
    local wallet="$1" receiving change receiving_unused change_unused error_file failed=0
    screen_header 'Wallet addresses' 'Deterministic receiving and change addresses known to Electrum.'
    error_file="$(mktemp /tmp/mgla-electrum-addresses.XXXXXX)"

    if receiving="$(electrum_cli -w "${wallet}" listaddresses --receiving --balance --labels 2>"${error_file}")"; then
        :
    else
        failed=1
    fi
    if receiving_unused="$(electrum_cli -w "${wallet}" listaddresses --receiving --unused 2>>"${error_file}")"; then
        :
    else
        failed=1
    fi
    if change="$(electrum_cli -w "${wallet}" listaddresses --change --balance --labels 2>>"${error_file}")"; then
        :
    else
        failed=1
    fi
    if change_unused="$(electrum_cli -w "${wallet}" listaddresses --change --unused 2>>"${error_file}")"; then
        :
    else
        failed=1
    fi

    if ((failed)) || [[ -z "${receiving}" || -z "${receiving_unused}" || -z "${change}" || -z "${change_unused}" ]]; then
        tty_line 'Could not read the wallet address list.'
        sed -n '1,12p' "${error_file}" 2>/dev/null || true
        rm -f -- "${error_file}"
        return 0
    fi

    if ! printf '{"receiving":%s,"receiving_unused":%s,"change":%s,"change_unused":%s}\n' \
        "${receiving}" "${receiving_unused}" "${change}" "${change_unused}" \
        | "${WALLET_VIEW_BIN}" addresses; then
        tty_line 'Electrum returned an unreadable address list.'
        sed -n '1,12p' "${error_file}" 2>/dev/null || true
    fi
    rm -f -- "${error_file}"
}

show_wallet_addresses() {
    show_screen render_wallet_addresses "$@"
}

render_wallet_coins() {
    local wallet="$1" coins error_file
    screen_header 'Wallet coins (UTXO)' 'Spendable outputs currently known to Electrum.'
    error_file="$(mktemp /tmp/mgla-electrum-coins.XXXXXX)"
    coins="$(electrum_cli -w "${wallet}" listunspent 2>"${error_file}" || true)"
    if [[ -z "${coins}" ]]; then
        tty_line 'Could not read the wallet UTXO set.'
        sed -n '1,12p' "${error_file}" 2>/dev/null || true
        rm -f -- "${error_file}"
        return 0
    fi
    if ! printf '%s\n' "${coins}" | "${WALLET_VIEW_BIN}" utxo; then
        tty_line 'Electrum returned an unreadable UTXO list.'
        sed -n '1,12p' "${error_file}" 2>/dev/null || true
    fi
    rm -f -- "${error_file}"
}

show_wallet_coins() {
    show_screen render_wallet_coins "$@"
}

render_wallet_info() {
    local wallet="$1" info
    screen_header 'Wallet info' 'Electrum wallet and network state.'
    info="$(electrum_cli -w "${wallet}" getinfo 2>/dev/null || true)"
    printf '%-16s %s\n' 'Wallet:' "$(basename "${wallet}")"
    printf '%-16s %s\n' 'Network:' "$(printf '%s\n' "${info}" | json_value network)"
    printf '%-16s %s\n' 'Connected:' "$(printf '%s\n' "${info}" | json_value connected)"
    printf '%-16s %s\n' 'Server:' "$(printf '%s\n' "${info}" | json_value server)"
    printf '%-16s %s\n' 'Local height:' "$(printf '%s\n' "${info}" | json_number_value blockchain_height)"
    printf '%-16s %s\n' 'Server height:' "$(printf '%s\n' "${info}" | json_number_value server_height)"
}

show_wallet_info() {
    show_screen render_wallet_info "$@"
}

render_wallet_sync() {
    local wallet="$1" status
    screen_header 'Wallet sync status' 'Checking whether Electrum has caught up with the selected server.'
    status="$(electrum_cli -w "${wallet}" is_synchronized 2>/dev/null || true)"
    case "${status}" in
        true) tty_line 'Synchronized: yes' ;;
        false) tty_line 'Synchronized: no' ;;
        *) tty_line 'Synchronized: unknown' ;;
    esac
}

show_wallet_sync() {
    show_screen render_wallet_sync "$@"
}

satkb_to_satvb() {
    local value="${1:-}"
    if [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        awk -v value="${value}" 'BEGIN { printf "%.1f", value / 1000 }'
    else
        printf '%s' 'n/a'
    fi
}

fee_from_info() {
    local info="$1" blocks="$2"
    awk -v key="\"${blocks}\"" '
        { data = data $0 }
        END {
            position = index(data, key)
            if (!position) exit
            value = substr(data, position + length(key))
            sub(/^[[:space:]]*:[[:space:]]*/, "", value)
            sub(/[,}].*$/, "", value)
            gsub(/"/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
        }
    ' <<< "${info}"
}

get_fee_rate() {
    local value
    value="$(electrum_cli getfeerate 2>/dev/null | grep -oE -- '^[0-9]+([.][0-9]+)?' | head -n 1 || true)"
    satkb_to_satvb "${value}"
}

load_fee_rates() {
    local __economy="$1" __standard="$2" __priority="$3" info fallback
    info="$(electrum_cli getinfo 2>/dev/null || true)"
    fallback="$(get_fee_rate)"
    set_fee_rate "${__priority}" "$(satkb_to_satvb "$(fee_from_info "${info}" 2)")"
    set_fee_rate "${__standard}" "$(satkb_to_satvb "$(fee_from_info "${info}" 5)")"
    set_fee_rate "${__economy}" "$(satkb_to_satvb "$(fee_from_info "${info}" 25)")"
    if [[ "${!__priority}" == n/a && "${!__standard}" == n/a && "${!__economy}" == n/a && "${fallback}" != n/a ]]; then
        printf -v "${__priority}" '%s' "${fallback}"
        printf -v "${__standard}" '%s' "${fallback}"
        printf -v "${__economy}" '%s' "${fallback}"
    fi
}

render_fee_estimates() {
    local economy standard priority
    screen_header 'Network fee' 'Electrum server estimates in sat/vB.'
    load_fee_rates economy standard priority
    printf '%-12s %s sat/vB\n' 'Economy:' "${economy}"
    printf '%-12s %s sat/vB\n' 'Standard:' "${standard}"
    printf '%-12s %s sat/vB\n' 'Priority:' "${priority}"
    tty_line ''
    tty_line 'RBF: enabled for transaction previews.'
}

show_fee_estimates() {
    if ensure_electrum_ready; then
        show_screen render_fee_estimates
    else
        pause_screen
    fi
}

choose_fee_rate() {
    local __var="$1" choice custom economy standard priority rc
    load_fee_rates economy standard priority
    screen_header 'Transaction fee' 'Choose a current Electrum estimate or enter a custom value.'
    printf '1. Economy (%s sat/vB)\n' "${economy}"
    printf '2. Standard (%s sat/vB)\n' "${standard}"
    printf '3. Priority (%s sat/vB)\n' "${priority}"
    tty_line '4. Custom sat/vB'
    tty_line 'b. Back'
    tty_line 'x. Exit'
    if read_menu_choice choice; then
        :
    else
        rc=$?
        return "${rc}"
    fi
    case "${choice}" in
        1) [[ "${economy}" != n/a ]] || return 1; printf -v "${__var}" '%s' "${economy}" ;;
        2) [[ "${standard}" != n/a ]] || return 1; printf -v "${__var}" '%s' "${standard}" ;;
        3) [[ "${priority}" != n/a ]] || return 1; printf -v "${__var}" '%s' "${priority}" ;;
        4)
            if prompt_value custom 'Custom fee' 'Enter a positive sat/vB value.'; then
                :
            else
                return $?
            fi
            if fee_rate_valid "${custom}"; then
                printf -v "${__var}" '%s' "${custom}"
            else
                screen_header 'Custom fee' 'The fee rate is invalid.'
                tty_line 'Use a positive decimal from 0.001 to 1000000 sat/vB.'
                pause_screen
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

address_is_valid() {
    local address="$1" result valid
    bitcoin_address_syntax_valid "${address}" || return 1
    result="$(electrum_cli validateaddress "${address}" 2>/dev/null || true)"
    valid="$(printf '%s\n' "${result}" | json_value isvalid)"
    [[ "${valid}" == true ]]
}

send_btc() {
    local wallet="$1" destination amount fee_rate unsigned_tx decoded signed_tx confirm fee vsize rc
    if prompt_value destination 'Send BTC' 'Enter the recipient Bitcoin address.'; then
        :
    else
        return $?
    fi
    if prompt_value amount 'Send BTC' 'Enter amount in BTC (use ! for the maximum).'; then
        :
    else
        return $?
    fi
    if [[ -z "${destination}" || -z "${amount}" ]]; then
        screen_header 'Send BTC' 'Transaction details are incomplete.'
        tty_line 'Recipient and amount are required.'
        pause_screen
        return 0
    fi
    if ! bitcoin_address_syntax_valid "${destination}"; then
        screen_header 'Send BTC' 'The recipient address format is invalid.'
        tty_line 'Use a mainnet Base58 or bech32 address without spaces.'
        pause_screen
        return 0
    fi
    if ! address_is_valid "${destination}"; then
        screen_header 'Send BTC' 'Electrum rejected the recipient address.'
        tty_line "Address: ${destination}"
        pause_screen
        return 0
    fi
    if [[ "${amount}" != '!' ]]; then
        if ! btc_amount_valid "${amount}"; then
            screen_header 'Send BTC' 'The amount is invalid.'
            tty_line 'Use a positive BTC amount with up to 8 decimals and a maximum of 21000000 BTC.'
            pause_screen
            return 0
        fi
    fi
    if choose_fee_rate fee_rate; then
        :
    else
        return $?
    fi
    if ! fee_rate_valid "${fee_rate}"; then
        screen_header 'Send BTC' 'The selected fee rate is invalid.'
        tty_line 'The transaction was not created.'
        pause_screen
        return 0
    fi

    screen_header 'Transaction preview' 'Creating an unsigned transaction. Nothing is broadcast yet.'
    unsigned_tx="$(electrum_cli -w "${wallet}" payto "${destination}" "${amount}" --feerate "${fee_rate}" --unsigned --rbf true 2>/tmp/electrum-payto.err || true)"
    if [[ -z "${unsigned_tx}" ]]; then
        tty_line 'Could not create an unsigned transaction.'
        sed -n '1,12p' /tmp/electrum-payto.err 2>/dev/null || true
        pause_screen
        return 0
    fi
    decoded="$(electrum_cli deserialize "${unsigned_tx}" 2>/dev/null || true)"
    fee="$(printf '%s\n' "${decoded}" | json_number_value fee)"
    vsize="$(printf '%s\n' "${decoded}" | json_number_value vsize)"
    printf '%-14s %s\n' 'Recipient:' "${destination}"
    printf '%-14s %s BTC\n' 'Amount:' "${amount}"
    printf '%-14s %s sat/vB\n' 'Fee rate:' "${fee_rate}"
    printf '%-14s %s sats\n' 'Fee:' "${fee:-unknown}"
    printf '%-14s %s vB\n' 'Size:' "${vsize:-unknown}"
    tty_line 'RBF: enabled'
    tty_line ''
    tty_line 'Bitcoin transactions are irreversible.'
    tty_line 'Type YES to sign and broadcast this transaction.'
    if prompt_value confirm 'Broadcast transaction' 'Type YES to continue; anything else cancels.'; then
        :
    else
        unset unsigned_tx decoded
        return $?
    fi
    if [[ "${confirm}" != YES ]]; then
        screen_header 'Send BTC' 'Transaction cancelled.'
        pause_screen
        unset unsigned_tx decoded
        return 0
    fi

    signed_tx="$(electrum_cli -w "${wallet}" signtransaction "${unsigned_tx}" 2>/tmp/electrum-sign.err || true)"
    if [[ "${signed_tx}" == \{* ]]; then
        signed_tx="$(printf '%s\n' "${signed_tx}" | json_value hex)"
    fi
    if [[ -z "${signed_tx}" ]]; then
        screen_header 'Send BTC' 'Could not sign the transaction.'
        sed -n '1,12p' /tmp/electrum-sign.err 2>/dev/null || true
        pause_screen
        unset unsigned_tx decoded signed_tx
        return 0
    fi
    screen_header 'Send BTC' 'Broadcasting the signed transaction through Tor.'
    if electrum_cli broadcast "${signed_tx}"; then
        tty_line 'Broadcast accepted by the selected Electrum server.'
    else
        tty_line 'Broadcast failed. The signed transaction was not confirmed by the server.'
    fi
    pause_screen
    unset unsigned_tx decoded signed_tx confirm fee vsize rc
}

wallet_menu() {
    local wallet="$1" choice rc
    vault_mark_dirty
    while true; do
        screen_header 'Bitcoin Electrum wallet' "Wallet: $(basename "${wallet}")"
        tty_line '1. Balance'
        tty_line '2. Transaction history'
        tty_line '3. Addresses'
        tty_line '4. Coins (UTXO)'
        tty_line '5. Receive address'
        tty_line '6. New receive address'
        tty_line '7. Send BTC'
        tty_line '8. Sync status'
        tty_line '9. Fee estimates'
        tty_line '10. Wallet info'
        tty_line '11. Change wallet password'
        tty_line ''
        tty_line 'b. Back'
        tty_line 'x. Exit'
        if read_menu_choice choice; then
            :
        else
            rc=$?
            [[ "${rc}" -eq 2 ]] && return 0
            return 0
        fi
        case "${choice}" in
            1) show_wallet_balance "${wallet}" ;;
            2) show_transaction_history "${wallet}" ;;
            3) show_wallet_addresses "${wallet}" ;;
            4) show_wallet_coins "${wallet}" ;;
            5) show_receive_address "${wallet}" ;;
            6) show_new_receive_address "${wallet}" ;;
            7) send_btc "${wallet}" ;;
            8) show_wallet_sync "${wallet}" ;;
            9) show_fee_estimates ;;
            10) show_wallet_info "${wallet}" ;;
            11)
                screen_header 'Change wallet password' 'Electrum will ask for the current and new passwords.'
                electrum_tty -w "${wallet}" password || true
                pause_screen
                ;;
            *) ;;
        esac
    done
}

render_network_info() {
    local info
    screen_header 'Network status' 'Electrum connection through the internal Tor broker.'
    info="$(electrum_cli getinfo 2>/dev/null || true)"
    printf '%-16s %s\n' 'Connected:' "$(printf '%s\n' "${info}" | json_value connected)"
    printf '%-16s %s\n' 'Network:' "$(printf '%s\n' "${info}" | json_value network)"
    printf '%-16s %s\n' 'Server:' "$(printf '%s\n' "${info}" | json_value server)"
    printf '%-16s %s\n' 'Local height:' "$(printf '%s\n' "${info}" | json_number_value blockchain_height)"
    printf '%-16s %s\n' 'Server height:' "$(printf '%s\n' "${info}" | json_number_value server_height)"
    tty_line 'Proxy: SOCKS5 with remote DNS through HAProxy'
}

show_network_info() {
    if ensure_electrum_ready; then
        show_screen render_network_info
    else
        pause_screen
    fi
}

render_servers() {
    local index
    screen_header 'Official Electrum onion servers' "Source: ${SERVER_SOURCE}"
    for index in "${!SERVER_CANDIDATES[@]}"; do
        printf '%2d. %s\n' "$((index + 1))" "${SERVER_CANDIDATES[${index}]}"
    done
    tty_line ''
    tty_line "Current: $(current_server)"
}

show_servers() {
    if ensure_electrum_ready; then
        show_screen render_servers
    else
        pause_screen
    fi
}

switch_server() {
    local choice server rc
    if ! ensure_electrum_ready; then
        pause_screen
        return 0
    fi
    screen_header 'Switch Electrum server' 'Only TLS .onion servers from the official list are accepted.'
    for choice in "${!SERVER_CANDIDATES[@]}"; do
        printf '%2d. %s\n' "$((choice + 1))" "${SERVER_CANDIDATES[${choice}]}"
    done
    tty_line 'b. Back'
    tty_line 'x. Exit'
    if read_menu_choice choice; then
        :
    else
        rc=$?
        [[ "${rc}" -eq 2 ]] && return 0
        return 0
    fi
    if ! menu_index_valid "${choice}" "${#SERVER_CANDIDATES[@]}"; then
        return 0
    fi
    server="${SERVER_CANDIDATES[$((10#${choice} - 1))]}"
    electrum_ready=0
    discovered_server=""
    stop_daemon
    set_config server "${server}"
    if start_daemon; then
        discovered_server="${server}"
        electrum_ready=1
        screen_header 'Switch Electrum server' 'Server changed.'
        tty_line "Server: ${server}"
    else
        screen_header 'Switch Electrum server' 'The selected server did not respond.'
    fi
    pause_screen
}

render_diagnostics() {
    screen_header 'Diagnostics' 'Electrum version and transport policy.'
    printf '%-20s %s\n' 'Electrum:' "$(electrum_version)"
    printf '%-20s %s\n' 'Server:' "$(current_server)"
    printf '%-20s %s\n' 'Proxy:' "$(electrum_probe getconfig proxy 2>/dev/null || true)"
    printf '%-20s %s\n' 'Proxy enabled:' "$(electrum_probe getconfig enable_proxy 2>/dev/null || true)"
    printf '%-20s %s\n' 'Auto-connect:' "$(electrum_probe getconfig auto_connect 2>/dev/null || true)"
    printf '%-20s %s\n' 'One server:' "$(electrum_probe getconfig oneserver 2>/dev/null || true)"
    printf '%-20s %s\n' 'Onion filtering:' "$(electrum_probe getconfig noonion 2>/dev/null || true)"
    tty_line ''
    tty_line 'Private keys stay in the local wallet file.'
    tty_line 'All Electrum network connections use the configured Tor SOCKS proxy.'
}

show_diagnostics() {
    if ensure_electrum_ready; then
        show_screen render_diagnostics
    else
        pause_screen
    fi
}

if [[ "${MGLA_VALIDATE_ONLY:-0}" == 1 ]]; then
    trap - EXIT
    if run_input_validation_tests; then
        exit 0
    fi
    exit 1
fi

if [[ "${MGLA_CI:-0}" != 1 ]]; then
    set +e
    choose_vault_mode
    vault_rc=$?
    set -e
    if [[ "${vault_rc}" -eq 2 ]]; then
        exit 0
    fi
    if [[ "${vault_rc}" -ne 0 ]]; then
        exit 1
    fi
    stop_daemon
    if ! clear_wallet_root; then
        printf '%s\n' '[error] could not clear the temporary discovery workspace' >&2
        exit 1
    fi
    if ! open_or_create_vault; then
        clear_wallet_root
        exit 1
    fi
fi

if ! configure_electrum; then
    exit 1
fi

if ! ensure_electrum_ready; then
    exit 1
fi

if [[ "${MGLA_CI:-0}" == 1 ]]; then
    info="$(electrum_cli getinfo 2>/dev/null || true)"
    if [[ "$(printf '%s\n' "${info}" | json_value connected)" != true ]]; then
        printf '%s\n' '[error] Electrum is not connected after onion discovery' >&2
        exit 1
    fi
    printf '%s\n' '[ok] Electrum onion discovery and SOCKS proxy check passed'
    exit 0
fi

while true; do
    version="$(electrum_version)"
    screen_header 'Bitcoin Electrum CLI' "${version:-version unknown}"
    tty_line '1. Network status'
    tty_line '2. Create wallet'
    tty_line '3. Restore wallet from seed'
    tty_line '4. Open wallet'
    tty_line '5. Fee estimates'
    tty_line '6. Official onion servers'
    tty_line '7. Switch server'
    tty_line '8. Diagnostics'
    tty_line ''
    tty_line 'x. Exit'
    if read_menu_choice choice; then
        :
    else
        rc=$?
        [[ "${rc}" -eq 2 ]] && exit_app
        continue
    fi
    case "${choice}" in
        1) show_network_info ;;
        2) create_wallet ;;
        3) restore_wallet ;;
        4) show_wallets ;;
        5) show_fee_estimates ;;
        6) show_servers ;;
        7) switch_server ;;
        8) show_diagnostics ;;
        *) ;;
    esac
done
