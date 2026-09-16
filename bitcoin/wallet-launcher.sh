#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

if [[ "$(id -u)" == 0 ]]; then
    printf '%s\n' '[error] the Bitcoin wallet must run as a non-root user' >&2
    exit 1
fi

ELECTRUM_BIN="/opt/venv/bin/electrum"
QR_BIN="/opt/venv/bin/qr"
ELECTRUMDIR="${ELECTRUMDIR:-/home/electrum/.electrum/bitcoin}"
WALLETS_DIR="${ELECTRUMDIR}/wallets"

if [[ "${ELECTRUMDIR}" != "/home/electrum/.electrum/bitcoin" ]]; then
    printf '%s\n' '[error] ELECTRUMDIR must remain the private tmpfs wallet directory' >&2
    exit 1
fi
HAPROXY_IP="${HAPROXY_IP:?HAPROXY_IP is required}"
PROXY_CONFIG="socks5:${HAPROXY_IP}:9095"
SERVER_SOURCE="https://github.com/spesmilo/electrum/blob/master/electrum/chains/mainnet/servers.json"
DEFAULT_SERVER="${ELECTRUM_DEFAULT_SERVER:-electrum.blockstream.info:50002:s}"

SERVER_CANDIDATES=(
    "bejqtnc64qttdempkczylydg7l3ordwugbdar7yqbndck53ukx7wnwad.onion:50002:s"
    "egyh5mutxwcvwhlvjubf6wytwoq5xxvfb2522ocx77puc6ihmffrh6id.onion:50002:s"
    "kittycp2gatrqhlwpmbczk5rblw62enrpo2rzwtkfrrr27hq435d4vid.onion:50002:s"
    "nuzzg3pku3xbctgamzq3pf7ztakkiidnmmier64arqwh3ajdddovatad.onion:50002:s"
    "qly7g5n5t3f3h23xvbp44vs6vpmayurno4basuu5rcvrupli7y2jmgid.onion:50002:s"
    "rzspa374ob3hlyjptkdgz6a62wim2mpanuw6m3shlwn2cxg2smy3p7yd.onion:50004:s"
    "ty6cgwaf2pbc244gijtmpfvte3wwfp32wgz57eltjkgtsel2q7jufjyd.onion:50002:s"
    "udfpzbte2hommnvag5f3qlouqkhvp3xybhlus2yvfeqdwlhjroe4bbyd.onion:60002:s"
    "venmrle3xuwkgkd42wg7f735l6cghst3sdfa3w3ryib2rochfhld6lid.onion:50002:s"
    "wsw6tua3xl24gsmi264zaep6seppjyrkyucpsmuxnjzyt3f3j6swshad.onion:50002:s"
)

tty_is_tty=0
electrum_child_pid=""
probe_height=""
vault_root="/home/electrum/.electrum"
vault_root_expected="/home/electrum/.electrum"
wallet_root="${ELECTRUMDIR}"
vault_binary="/opt/bitcoin/mgla-vault"
vault_store="/bitcoin/vault-store"
vault_host_dir="${WALLET_VAULT_HOST_DIR:-${HOME}/.mgla}"
vault_size="${WALLET_VAULT_SIZE:-128M}"
vault_file=""
vault_host_path=""
vault_loaded=0
vault_dirty=0
vault_layout_migrated=0
vault_mode="${MGLA_VAULT_MODE:-}"
vault_session_dir=""
vault_session_socket=""
vault_session_pid=""

readonly MAX_INPUT_LENGTH=512
readonly MAX_BTC_SATS=2100000000000000
readonly MAX_FEE_RATE_MILLISATVB=1000000000
readonly PROBE_ATTEMPTS=20

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

if [[ ! -x "${QR_BIN}" ]]; then
    printf '[error] QR renderer is missing: %s\n' "${QR_BIN}" >&2
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

stop_daemon() {
    electrum_probe stop >/dev/null 2>&1 || true
}

on_signal() {
    if [[ -n "${electrum_child_pid}" ]]; then
        kill -INT "${electrum_child_pid}" >/dev/null 2>&1 || true
    fi
    exit 130
}

cleanup() {
    local exit_code=$?

    if [[ "${cleanup_done:-0}" -eq 1 ]]; then
        return "${exit_code}"
    fi
    cleanup_done=1

    restore_tty
    stop_daemon
    if declare -F save_vault >/dev/null 2>&1 && [[ "${vault_loaded:-0}" -eq 1 ]]; then
        save_vault || true
    fi
    if declare -F stop_vault_session >/dev/null 2>&1; then
        stop_vault_session || true
    fi
    if declare -F clear_wallet_root >/dev/null 2>&1; then
        clear_wallet_root
    fi

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
    local __var="$1" prompt="$2" value=""
    tty_write "${prompt}"
    if tty_available; then
        if ! IFS= read -r value < /dev/tty; then
            return 1
        fi
    else
        if ! IFS= read -r value; then
            return 1
        fi
    fi
    value="${value//$'\r'/}"
    if (( ${#value} > MAX_INPUT_LENGTH )); then
        tty_line '[error] input is too long.'
        return 1
    fi
    if [[ "${value}" == *[[:cntrl:]]* ]]; then
        tty_line '[error] control characters are not allowed.'
        return 1
    fi
    printf -v "${__var}" '%s' "${value}"
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
    tty_line 'Press Enter to return.'
    tty_line ''
    if read_line value '?: '; then
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
        if ! read_line action '?: '; then
            return 0
        fi
        if is_exit "${action}"; then
            exit_app
        fi
        if is_back "${action}" || [[ -z "${action}" ]]; then
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
    local prompt="$1" value=""

    if read_line value "${prompt}"; then
        printf '%s' "${value}"
    else
        printf '%s' ''
    fi
}

vault_pause_or_enter() {
    pause_screen
}

# ---- encrypted wallet vault lifecycle ----

vault_with_tty_password() {
    "$vault_binary" --tty-password "$@"
}

choose_vault_mode() {
    local choice

    case "${vault_mode}" in
        prompt|session)
            return 0
            ;;
    esac

    while true; do
        clear_screen
        tty_line "Vault unlock mode"
        tty_line "------------------------------------------------------------"
        tty_line "Choose how the vault key is held while this launcher is running."
        vault_tty_blank
        tty_line "1. Prompt"
        tty_line "   Ask for the vault password on every open and save."
        tty_line "   The derived key is discarded after each operation."
        vault_tty_blank
        tty_line "2. Session"
        tty_line "   Enter the password once and keep only the derived key"
        tty_line "   in locked memory until the launcher exits."
        vault_tty_blank
        tty_line "b. Back"
        tty_line "x. Exit"
        vault_tty_blank

        choice="$(vault_read_choice "?: ")"
        case "${choice}" in
            1)
                vault_mode="prompt"
                return 0
                ;;
            2)
                vault_mode="session"
                return 0
                ;;
            b|B|x|X)
                return 2
                ;;
        esac
    done
}

vault_session_request() {
    local command="${1:-}"

    [[ "${vault_mode}" == "session" ]] || return 1
    [[ -n "${vault_session_socket}" && -S "${vault_session_socket}" ]] || return 1
    "$vault_binary" session-request "${vault_session_socket}" "${command}" >/dev/null 2>&1
}

stop_vault_session() {
    local pid="${vault_session_pid:-}"
    local socket="${vault_session_socket:-}"
    local session_dir="${vault_session_dir:-}"
    local i

    if [[ -n "${socket}" && -S "${socket}" ]]; then
        "$vault_binary" session-request "${socket}" shutdown >/dev/null 2>&1 || true
    fi

    if [[ -n "${pid}" ]]; then
        for ((i = 0; i < 20; i++)); do
            if ! kill -0 "${pid}" 2>/dev/null; then
                wait "${pid}" 2>/dev/null || true
                break
            fi
            sleep 0.1
        done

        if kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
        for ((i = 0; i < 20; i++)); do
            if ! kill -0 "${pid}" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        if kill -0 "${pid}" 2>/dev/null; then
            kill -KILL "${pid}" 2>/dev/null || true
        fi
        wait "${pid}" 2>/dev/null || true
    fi

    if [[ -n "${socket}" ]]; then
        rm -f -- "${socket}" 2>/dev/null || true
    fi
    if [[ -n "${session_dir}" ]]; then
        rmdir -- "${session_dir}" 2>/dev/null || true
    fi

    vault_session_pid=""
    vault_session_socket=""
    vault_session_dir=""
}

start_vault_session() {
    local action="${1:-}"
    local i
    local pid

    [[ "${vault_mode}" == "session" ]] || return 0
    if [[ -n "${vault_session_pid}" ]]; then
        return 0
    fi

    if ! vault_session_dir="$(mktemp -d /tmp/mgla-vault-session.XXXXXX 2>/dev/null)"; then
        tty_line "error: cannot create private vault session directory"
        return 1
    fi
    if ! chmod 700 "${vault_session_dir}"; then
        tty_line "error: cannot protect vault session directory"
        stop_vault_session
        return 1
    fi
    vault_session_socket="${vault_session_dir}/vault.sock"

    tty_line "Starting protected vault session..."
    case "${action}" in
        open)
            "$vault_binary" session-open \
                "${vault_file}" "${vault_root}" "${vault_session_socket}" \
                </dev/tty >/dev/tty 2>/dev/tty &
            ;;
        create)
            "$vault_binary" session-create-generated \
                "${vault_file}" "${vault_size}" "${vault_root}" \
                "${vault_root}" "${vault_session_socket}" \
                </dev/tty >/dev/tty 2>/dev/tty &
            ;;
        *)
            tty_line "error: invalid vault session action"
            stop_vault_session
            return 1
            ;;
    esac
    vault_session_pid=$!
    pid="${vault_session_pid}"

    for ((i = 0; i < 1800; i++)); do
        if [[ -S "${vault_session_socket}" ]]; then
            return 0
        fi
        if ! kill -0 "${pid}" 2>/dev/null; then
            wait "${pid}" 2>/dev/null || true
            tty_line "error: vault session stopped unexpectedly"
            stop_vault_session
            return 1
        fi
        sleep 0.1
    done

    tty_line "error: vault session did not start"
    stop_vault_session
    return 1
}

clear_wallet_root() {
    [[ "${vault_root}" == "${vault_root_expected}" ]] || return 1
    [[ -d "${vault_root}" ]] || return 0
    find "${vault_root}" -mindepth 1 -exec rm -rf -- {} + 2>/dev/null || true
}

move_legacy_vault_entries() {
    local target="$1" path name target_name

    target_name="${target##*/}"
    if ! install -d -m 0700 "${target}"; then
        return 1
    fi
    while IFS= read -r -d '' path; do
        name="${path##*/}"
        if [[ "${name}" == "${target_name}" ]]; then
            continue
        fi
        if [[ "${name}" == ".mgla-wallet-type" ]]; then
            rm -f -- "${path}"
        else
            mv -- "${path}" "${target}/"
        fi
    done < <(find "${vault_root}" -mindepth 1 -maxdepth 1 -print0)
}

legacy_monero_layout() {
    local path name

    for path in "${vault_root}"/*; do
        if [[ ! -d "${path}" ]]; then
            continue
        fi
        name="${path##*/}"
        if [[ -f "${path}/${name}" && -f "${path}/${name}.keys" ]]; then
            return 0
        fi
    done
    return 1
}

normalize_vault_layout() {
    local marker="" legacy_kind=""

    vault_layout_migrated=0
    if [[ -d "${vault_root}/monero" || -d "${vault_root}/bitcoin" ]]; then
        return 0
    fi

    if [[ -f "${vault_root}/.mgla-wallet-type" ]]; then
        IFS= read -r marker < "${vault_root}/.mgla-wallet-type" || true
        case "${marker}" in
            monero|bitcoin)
                legacy_kind="${marker}"
                ;;
        esac
    fi
    if [[ -z "${legacy_kind}" ]] && legacy_monero_layout; then
        legacy_kind="monero"
    fi
    if [[ -z "${legacy_kind}" &&
          ( -d "${vault_root}/wallets" || -f "${vault_root}/config" ) ]]; then
        legacy_kind="bitcoin"
    fi

    if [[ -n "${legacy_kind}" ]]; then
        if ! move_legacy_vault_entries "${vault_root}/${legacy_kind}"; then
            return 1
        fi
        vault_layout_migrated=1
        return 0
    fi

    if [[ -n "$(find "${vault_root}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        return 1
    fi
    return 0
}

ensure_wallet_root() {
    if [[ -e "${wallet_root}" && ! -d "${wallet_root}" ]]; then
        return 1
    fi
    install -d -m 0700 "${wallet_root}"
}

save_vault() {
    local saved=0

    [[ "${vault_loaded}" -eq 1 && "${vault_dirty}" -eq 1 ]] || return 0

    tty_line "Saving encrypted wallet vault..."
    if [[ "${vault_mode}" == "session" ]]; then
        if vault_session_request pack; then
            saved=1
        fi
    elif vault_with_tty_password pack "${vault_file}" "${vault_root}"; then
        saved=1
    fi

    if [[ "${saved}" -eq 1 ]]; then
        vault_dirty=0
        tty_line "[ok] encrypted wallet vault saved"
        return 0
    fi

    tty_line "[error] failed to save encrypted wallet vault"
    return 1
}

vault_name_valid() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.mgla$ ]]
}

set_vault_target() {
    local name="$1"

    vault_file="${vault_store}/${name}"
    vault_host_path="${vault_host_dir}/${name}"
}

list_vault_names() {
    local path name

    for path in "${vault_store}"/*.mgla; do
        [[ -f "${path}" ]] || continue
        name="${path##*/}"
        vault_name_valid "${name}" || continue
        printf '%s\n' "${name}"
    done | sort
}

prompt_new_vault() {
    local name

    while true; do
        clear_screen
        tty_line "Create encrypted wallet vault"
        tty_line "------------------------------------------------------------"
        tty_line "Enter a short name for the vault."
        tty_line "The .mgla extension is added automatically."
        tty_line "Allowed: A-Z, a-z, 0-9, ., _ and -"
        vault_tty_blank
        tty_line "b. Back"
        vault_tty_blank

        name="$(vault_read_choice "Vault name: ")"
        case "${name}" in
          b|B) return 2 ;;
        esac

        [[ -n "${name}" ]] || continue
        if [[ "${name}" != *.mgla ]]; then
            name="${name}.mgla"
        fi

        if ! vault_name_valid "${name}"; then
            tty_line "Invalid vault name."
            vault_pause_or_enter
            continue
        fi
        if [[ -e "${vault_store}/${name}" ]]; then
            tty_line "That vault name already exists or is reserved."
            vault_pause_or_enter
            continue
        fi

        set_vault_target "${name}"
        return 0
    done
}

choose_vault() {
    local -a names=()
    local name choice i

    while IFS= read -r name; do
        [[ -n "${name}" ]] && names+=("${name}")
    done < <(list_vault_names)

    while true; do
        clear_screen
        tty_line "Wallet vaults"
        tty_line "------------------------------------------------------------"
        tty_line "Vault directory: ${vault_host_dir}"
        vault_tty_blank

        if (( ${#names[@]} == 0 )); then
            tty_line "No encrypted vaults found."
        else
            tty_line "Vaults:"
            for ((i = 0; i < ${#names[@]}; i++)); do
                vault_tty_printf "%d.  %s\n" "$((i + 1))" "${names[i]}"
            done
        fi

        vault_tty_blank
        tty_line "n. Create new vault"
        tty_line "x. Exit"
        vault_tty_blank

        choice="$(vault_read_choice "?: ")"
        case "${choice}" in
          n|N)
            prompt_new_vault && return 0
            ;;
          x|X)
            return 1
            ;;
        esac

        [[ "${choice}" =~ ^[0-9]+$ ]] || continue
        (( ${#names[@]} > 0 && choice >= 1 && choice <= ${#names[@]} )) || continue
        set_vault_target "${names[$((choice - 1))]}"
        return 0
    done
}

open_or_create_vault() {
    if [[ ! -x "${vault_binary}" ]]; then
        tty_line "error: vault binary is missing"
        return 1
    fi
    if ! mkdir -p "${vault_store}" 2>/dev/null || ! chmod 700 "${vault_store}" 2>/dev/null; then
        tty_line "error: cannot access host vault directory"
        return 1
    fi
    if ! mkdir -p "${vault_root}" 2>/dev/null || ! chmod 700 "${vault_root}" 2>/dev/null; then
        tty_line "error: cannot access temporary vault directory"
        return 1
    fi
    if ! choose_vault; then
        return 1
    fi

    if [[ -f "${vault_file}" ]]; then
        while true; do
            clear_screen
            tty_line "Open encrypted wallet vault"
            tty_line "------------------------------------------------------------"
            tty_line "Vault file: ${vault_host_path}"
            vault_tty_blank

            if [[ "${vault_mode}" == "session" ]]; then
                if start_vault_session open && vault_session_request unpack; then
                    if ! normalize_vault_layout || ! ensure_wallet_root; then
                        stop_vault_session
                        clear_wallet_root
                        tty_line "error: unrecognized wallet vault layout"
                        return 1
                    fi
                    vault_loaded=1
                    vault_dirty="${vault_layout_migrated}"
                    tty_line "[ok] encrypted wallet vault opened"
                    return 0
                fi
                stop_vault_session
            elif vault_with_tty_password unpack "${vault_file}" "${vault_root}"; then
                if ! normalize_vault_layout || ! ensure_wallet_root; then
                    clear_wallet_root
                    tty_line "error: unrecognized wallet vault layout"
                    return 1
                fi
                vault_loaded=1
                vault_dirty="${vault_layout_migrated}"
                tty_line "[ok] encrypted wallet vault opened"
                return 0
            fi

            clear_wallet_root
            tty_line "error: wrong password or damaged vault"
            vault_tty_blank
            choice="$(vault_read_choice "Press Enter to try again, or x to exit: ")"
            [[ "${choice}" =~ ^[xX]$ ]] && return 1
        done
    fi

    clear_screen
    tty_line "Create encrypted wallet vault"
    tty_line "------------------------------------------------------------"
    tty_line "No vault found at: ${vault_host_path}"
    tty_line "A fixed-size ${vault_size} vault will be created."
    vault_tty_blank
    tty_line "A random password will be shown once. Save it offline."
    tty_line "If it is lost, the vault cannot be opened again."
    tty_line "Wallet seed phrases can restore wallets, but not local wallet data."
    vault_tty_blank

    if ! ensure_wallet_root; then
        tty_line "error: cannot initialize wallet directory"
        return 1
    fi
    if [[ "${vault_mode}" == "session" ]]; then
        if start_vault_session create; then
            vault_loaded=1
            vault_dirty=0
            tty_line "[ok] encrypted wallet vault created"
            vault_pause_or_enter
            return 0
        fi
        tty_line "error: failed to create encrypted wallet vault"
        return 1
    fi

    if "$vault_binary" create-generated "$vault_file" "$vault_size" "$vault_root"; then
        vault_loaded=1
        vault_dirty=0
        tty_line "[ok] encrypted wallet vault created"
        vault_pause_or_enter
        return 0
    else
        rc=$?
        if [[ "$rc" -eq 2 ]]; then
            return 1
        fi
        tty_line "error: failed to create encrypted wallet vault"
        return 1
    fi
}

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
    vault_dirty=1
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
    total="${#SERVER_CANDIDATES[@]}"

    screen_header "Electrum onion discovery" "Selecting the first working server through Tor."
    tty_line "Proxy: HAProxy SOCKS5 with remote DNS at ${HAPROXY_IP}:9095"
    tty_line "Candidates: ${total} official .onion servers"
    tty_line "Source: ${SERVER_SOURCE}"
    tty_line "Fallback: ${DEFAULT_SERVER}"
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
        tty_line 'No official Onion server responded; trying the default Electrum server through Tor.'
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

    stop_daemon
    set_config server "${selected_server}"
    vault_dirty=1
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
    vault_dirty=1
    electrum_tty -w "${wallet}" load_wallet
}

create_wallet() {
    local wallet seed answer rc
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
    tty_line 'x. Exit'
    if ! read_line answer '?: '; then
        unset seed
        return 0
    fi
    if is_exit "${answer}"; then
        unset seed
        exit_app
    fi
    unset seed

    screen_header 'Create wallet' 'Electrum will now ask for the seed and wallet password.'
    if electrum_tty -w "${wallet}" restore :; then
        wallet_menu "${wallet}"
    else
        rm -f -- "${wallet}"
        screen_header 'Create wallet' 'Wallet creation failed.'
        pause_screen
    fi
}

restore_wallet() {
    local wallet rc
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
    screen_header 'Restore wallet' 'Enter the existing seed in Electrum.'
    tty_line 'The seed and password are entered directly into Electrum.'
    tty_line ''
    if electrum_tty -w "${wallet}" restore :; then
        wallet_menu "${wallet}"
    else
        rm -f -- "${wallet}"
        screen_header 'Restore wallet' 'Wallet restoration failed.'
        pause_screen
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
            if unlock_wallet "${wallets[${index}]}"; then
                wallet_menu "${wallets[${index}]}"
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
    local wallet="$1" address uri
    screen_header 'Receive BTC' 'Use this address to receive bitcoin.'
    address="$(electrum_cli -w "${wallet}" getunusedaddress 2>/dev/null || true)"
    if [[ -z "${address}" || "${address}" == null ]]; then
        address="$(electrum_cli -w "${wallet}" createnewaddress 2>/dev/null || true)"
    fi
    uri="bitcoin:${address}"
    tty_line 'Address:'
    tty_line "${address}"
    tty_line ''
    tty_line "${uri}"
    tty_line ''
    "${QR_BIN}" --ascii "${uri}" || true
}

show_receive_address() {
    show_screen render_receive_address "$@"
}

render_new_receive_address() {
    local wallet="$1" address uri
    screen_header 'New receive address' 'Generate a fresh deterministic receiving address.'
    address="$(electrum_cli -w "${wallet}" createnewaddress 2>/dev/null || true)"
    uri="bitcoin:${address}"
    tty_line 'Address:'
    tty_line "${address}"
    tty_line ''
    tty_line "${uri}"
    tty_line ''
    "${QR_BIN}" --ascii "${uri}" || true
}

show_new_receive_address() {
    show_screen render_new_receive_address "$@"
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
    show_screen render_fee_estimates
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
    vault_dirty=1
    while true; do
        screen_header 'Bitcoin Electrum wallet' "Wallet: $(basename "${wallet}")"
        tty_line '1. Balance'
        tty_line '2. Receive address'
        tty_line '3. New receive address'
        tty_line '4. Send BTC'
        tty_line '5. Sync status'
        tty_line '6. Fee estimates'
        tty_line '7. Wallet info'
        tty_line '8. Change wallet password'
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
            2) show_receive_address "${wallet}" ;;
            3) show_new_receive_address "${wallet}" ;;
            4) send_btc "${wallet}" ;;
            5) show_wallet_sync "${wallet}" ;;
            6) show_fee_estimates ;;
            7) show_wallet_info "${wallet}" ;;
            8)
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
    show_screen render_network_info
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
    show_screen render_servers
}

switch_server() {
    local choice server rc
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
    stop_daemon
    set_config server "${server}"
    if start_daemon; then
        screen_header 'Switch Electrum server' 'Server changed.'
        tty_line "Server: ${server}"
    else
        screen_header 'Switch Electrum server' 'The selected server did not respond.'
    fi
    pause_screen
}

render_diagnostics() {
    screen_header 'Diagnostics' 'Electrum version and transport policy.'
    printf '%-20s %s\n' 'Electrum:' "$("${ELECTRUM_BIN}" --offline --version 2>/dev/null | head -n 1 || true)"
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
    show_screen render_diagnostics
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
    if ! open_or_create_vault; then
        clear_wallet_root
        exit 1
    fi
fi

if ! configure_electrum; then
    exit 1
fi
if ! discover_best_server; then
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
    version="$("${ELECTRUM_BIN}" --offline --version 2>/dev/null | head -n 1 || true)"
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
