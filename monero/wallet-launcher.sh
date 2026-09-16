#!/bin/bash
set -Eeuo pipefail

if [[ "$(id -u)" == 0 ]]; then
    printf '%s\n' '[error] the Monero wallet must run as a non-root user' >&2
    exit 1
fi

tty_is_tty=0
if [[ -r /dev/tty ]]; then
    tty_is_tty=1
    __orig_stty="$(stty -g < /dev/tty 2>/dev/null || true)"
    stty -echoctl < /dev/tty 2>/dev/null || true
fi

clear_screen() {
    if [[ -w /dev/tty ]]; then
        # clear + move cursor home + clear scrollback
        printf '\033[2J\033[H\033[3J' > /dev/tty
    else
        clear 2>/dev/null || true
        printf '\033[3J' 2>/dev/null || true
    fi
}

restore_tty() {
    tput cnorm 2>/dev/null || true
    if [[ "${tty_is_tty}" -eq 1 ]]; then
        [[ -n "${__orig_stty:-}" ]] && stty "${__orig_stty}" 2>/dev/null || true
    fi
}

cleanup() {
    local exit_code=$?

    if [[ "${cleanup_done:-0}" -eq 1 ]]; then
        return "${exit_code}"
    fi
    cleanup_done=1

    if declare -F stop_wallet_child >/dev/null 2>&1; then
        stop_wallet_child
    fi
    # Persist dirty wallet data before clearing the temporary wallet root,
    # including signal and error exits.
    if declare -F save_vault >/dev/null 2>&1 && [[ "${vault_loaded:-0}" -eq 1 ]]; then
        save_vault || true
    fi
    if declare -F stop_vault_session >/dev/null 2>&1; then
        stop_vault_session || true
    fi
    if declare -F clear_wallet_root >/dev/null 2>&1; then
        clear_wallet_root
    fi

    restore_tty
    return "${exit_code}"
}

stop_wallet_child() {
    local pid="${wallet_pid:-}"
    local i

    [[ -n "${pid}" ]] || return 0

    kill -INT "${pid}" 2>/dev/null || true
    for i in 1 2 3 4 5; do
        kill -0 "${pid}" 2>/dev/null || return 0
        sleep 0.1
    done

    kill -TERM "${pid}" 2>/dev/null || true
    for i in 1 2 3 4 5; do
        kill -0 "${pid}" 2>/dev/null || return 0
        sleep 0.1
    done

    kill -KILL "${pid}" 2>/dev/null || true
}

on_sigint() {
    stop_wallet_child
    clear_screen
    restore_tty
    echo
    echo "Interrupted by Ctrl+C. Exiting..."
    exit 130
}

on_sigterm() {
    stop_wallet_child
    restore_tty
    echo
    echo "Received SIGTERM. Exiting..."
    exit 143
}

trap on_sigint INT
trap on_sigterm TERM
trap 'cleanup' EXIT

wallet_pid=""
cleanup_done=0
socks_port="${socks_port:-9095}"
vault_root="/monero/wallets"
vault_root_expected="/monero/wallets"
wallet_root="${vault_root}/monero"
vault_binary="/opt/monero/mgla-vault"
vault_store="/monero/vault-store"
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
daemon_mode="${daemon_mode:-untrusted}"

if [[ -z "${HAPROXY_IP:-}" ]]; then
    echo "error: HAPROXY_IP is empty"
    exit 1
fi

proxy="${HAPROXY_IP}:${socks_port}"

# ---- daemon discovery (UI to /dev/tty only; nothing to container stdout/stderr) ----

tty_ok() { [[ -r /dev/tty && -w /dev/tty ]]; }

tty_print() {
    tty_ok || return 0
    printf '%s\n' "$*" > /dev/tty
}

tty_blank() {
    tty_ok || return 0
    printf '\n' > /dev/tty
}

tty_printf() {
    tty_ok || return 0
    # shellcheck disable=SC2059
    printf "$@" > /dev/tty
}

_trim() {
    local s="$1"
    s="${s//$'\r'/}"
    s="${s//$'\n'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf "%s" "$s"
}

read_choice() {
    local prompt="$1"
    local out=""
    if tty_ok; then
        tty_printf "%s" "$prompt"
        IFS= read -r out < /dev/tty || out=""
    else
        out=""
    fi
    _trim "$out"
}

pause_or_enter() {
    # Enter OR 4 seconds (TTY only; otherwise do nothing to avoid logs)
    if tty_ok; then
        tty_printf "Press Enter to continue (or wait 4 seconds)... "
        read -r -t 4 _ < /dev/tty || true
        tty_blank
    else
        sleep 4
    fi
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
        tty_print "Vault unlock mode"
        tty_print "------------------------------------------------------------"
        tty_print "Choose how the vault key is held while this launcher is running."
        tty_blank
        tty_print "1. Prompt"
        tty_print "   Ask for the vault password on every open and save."
        tty_print "   The derived key is discarded after each operation."
        tty_blank
        tty_print "2. Session"
        tty_print "   Enter the password once and keep only the derived key"
        tty_print "   in locked memory until the launcher exits."
        tty_blank
        tty_print "b. Back"
        tty_print "x. Exit"
        tty_blank

        choice="$(read_choice "?: ")"
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
        tty_print "error: cannot create private vault session directory"
        return 1
    fi
    if ! chmod 700 "${vault_session_dir}"; then
        tty_print "error: cannot protect vault session directory"
        stop_vault_session
        return 1
    fi
    vault_session_socket="${vault_session_dir}/vault.sock"

    tty_print "Starting protected vault session..."
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
            tty_print "error: invalid vault session action"
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
            tty_print "error: vault session stopped unexpectedly"
            stop_vault_session
            return 1
        fi
        sleep 0.1
    done

    tty_print "error: vault session did not start"
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

    tty_print "Saving encrypted wallet vault..."
    if [[ "${vault_mode}" == "session" ]]; then
        if vault_session_request pack; then
            saved=1
        fi
    elif vault_with_tty_password pack "${vault_file}" "${vault_root}"; then
        saved=1
    fi

    if [[ "${saved}" -eq 1 ]]; then
        vault_dirty=0
        tty_print "[ok] encrypted wallet vault saved"
        return 0
    fi

    tty_print "[error] failed to save encrypted wallet vault"
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
        tty_print "Create encrypted wallet vault"
        tty_print "------------------------------------------------------------"
        tty_print "Enter a short name for the vault."
        tty_print "The .mgla extension is added automatically."
        tty_print "Allowed: A-Z, a-z, 0-9, ., _ and -"
        tty_blank
        tty_print "b. Back"
        tty_blank

        name="$(read_choice "Vault name: ")"
        case "${name}" in
          b|B) return 2 ;;
        esac

        [[ -n "${name}" ]] || continue
        if [[ "${name}" != *.mgla ]]; then
            name="${name}.mgla"
        fi

        if ! vault_name_valid "${name}"; then
            tty_print "Invalid vault name."
            pause_or_enter
            continue
        fi
        if [[ -e "${vault_store}/${name}" ]]; then
            tty_print "That vault name already exists or is reserved."
            pause_or_enter
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
        tty_print "Wallet vaults"
        tty_print "------------------------------------------------------------"
        tty_print "Vault directory: ${vault_host_dir}"
        tty_blank

        if (( ${#names[@]} == 0 )); then
            tty_print "No encrypted vaults found."
        else
            tty_print "Vaults:"
            for ((i = 0; i < ${#names[@]}; i++)); do
                tty_printf "%d.  %s\n" "$((i + 1))" "${names[i]}"
            done
        fi

        tty_blank
        tty_print "n. Create new vault"
        tty_print "x. Exit"
        tty_blank

        choice="$(read_choice "?: ")"
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
        tty_print "error: vault binary is missing"
        return 1
    fi
    if ! mkdir -p "${vault_store}" 2>/dev/null || ! chmod 700 "${vault_store}" 2>/dev/null; then
        tty_print "error: cannot access host vault directory"
        return 1
    fi
    if ! mkdir -p "${vault_root}" 2>/dev/null || ! chmod 700 "${vault_root}" 2>/dev/null; then
        tty_print "error: cannot access temporary vault directory"
        return 1
    fi
    if ! choose_vault; then
        return 1
    fi

    if [[ -f "${vault_file}" ]]; then
        while true; do
            clear_screen
            tty_print "Open encrypted wallet vault"
            tty_print "------------------------------------------------------------"
            tty_print "Vault file: ${vault_host_path}"
            tty_blank

            if [[ "${vault_mode}" == "session" ]]; then
                if start_vault_session open && vault_session_request unpack; then
                    if ! normalize_vault_layout || ! ensure_wallet_root; then
                        stop_vault_session
                        clear_wallet_root
                        tty_print "error: unrecognized wallet vault layout"
                        return 1
                    fi
                    vault_loaded=1
                    vault_dirty="${vault_layout_migrated}"
                    tty_print "[ok] encrypted wallet vault opened"
                    return 0
                fi
                stop_vault_session
            elif vault_with_tty_password unpack "${vault_file}" "${vault_root}"; then
                if ! normalize_vault_layout || ! ensure_wallet_root; then
                    clear_wallet_root
                    tty_print "error: unrecognized wallet vault layout"
                    return 1
                fi
                vault_loaded=1
                vault_dirty="${vault_layout_migrated}"
                tty_print "[ok] encrypted wallet vault opened"
                return 0
            fi

            clear_wallet_root
            tty_print "error: wrong password or damaged vault"
            tty_blank
            choice="$(read_choice "Press Enter to try again, or x to exit: ")"
            [[ "${choice}" =~ ^[xX]$ ]] && return 1
        done
    fi

    clear_screen
    tty_print "Create encrypted wallet vault"
    tty_print "------------------------------------------------------------"
    tty_print "No vault found at: ${vault_host_path}"
    tty_print "A fixed-size ${vault_size} vault will be created."
    tty_blank
    tty_print "A random password will be shown once. Save it offline."
    tty_print "If it is lost, the vault cannot be opened again."
    tty_print "Wallet seed phrases can restore wallets, but not local wallet data."
    tty_blank

    if ! ensure_wallet_root; then
        tty_print "error: cannot initialize wallet directory"
        return 1
    fi
    if [[ "${vault_mode}" == "session" ]]; then
        if start_vault_session create; then
            vault_loaded=1
            vault_dirty=0
            tty_print "[ok] encrypted wallet vault created"
            return 0
        fi
        tty_print "error: failed to create encrypted wallet vault"
        return 1
    fi

    if "$vault_binary" create-generated "$vault_file" "$vault_size" "$vault_root"; then
        vault_loaded=1
        vault_dirty=0
        tty_print "[ok] encrypted wallet vault created"
        return 0
    else
        rc=$?
        if [[ "$rc" -eq 2 ]]; then
            return 1
        fi
        tty_print "error: failed to create encrypted wallet vault"
        return 1
    fi
}

_xmr_nodes_raw() {
    local html=""
    local url

    # Last-resort compatibility path for the original onion mirror. This is
    # intentionally bounded and is used only when the current feeds are empty.
    url='http://livk2fpdv4xjnjrbxfz2tw3ptogqacn2dwfzxbxr3srinryxrcewemid.onion/?chain=monero&network=mainnet&type=onion'
    html="$(curl -fsS -L --max-time 12 --proxy "socks5h://${proxy}" "$url" 2>/dev/null || true)"
    if [[ -n "${html}" ]]; then
        printf '%s' "$html" \
          | tr '\n' ' ' \
          | sed 's/<tr/\n<tr/g' \
          | grep '^<tr' \
          | awk '
            {
              r=$0
              if (!match(r, /[a-z2-7]{56}\.onion:[0-9][0-9][0-9]?[0-9]?[0-9]?/)) next
              a=substr(r,RSTART,RLENGTH); split(a,hp,":"); h=hp[1]; p=hp[2]

              if (!match(r, /[0-9][0-9][0-9][0-9][0-9][0-9][0-9]*/)) next
              b=substr(r,RSTART,RLENGTH)

              g=0; d=r; while (match(d,/glowing-green/)) {g++; d=substr(d,RSTART+RLENGTH)}
              e=0; d=r; while (match(d,/glowing-red/)) {e++; d=substr(d,RSTART+RLENGTH)}
              t=g+e; if (t!=6 || g<5) next

              printf "%s\t%s\t%s\n", h,p,b
            }' || true
    fi
}

node_is_alive() {
    local host="$1" port="$2"
    curl -fsS --connect-timeout 5 --max-time 10 \
        --proxy "socks5h://${proxy}" \
        "http://${host}:${port}/get_info" >/dev/null 2>&1
}

pick_best_node() {
    local rounds="${1:-2}"
    local topn="${2:-15}"
    local used=""

    local host port blocks
    while (( rounds > 0 )); do
        while IFS=$'\t' read -r host port blocks; do
            [[ -z "${host:-}" || -z "${port:-}" ]] && continue

            if [[ " $used " == *" ${host}:${port} "* ]]; then
                continue
            fi

            if node_is_alive "$host" "$port"; then
                printf "%s %s %s\n" "$host" "$port" "$blocks"
                return 0
            fi

            used+=" ${host}:${port}"
        done < <(_xmr_nodes_raw | sort -t$'\t' -k3,3nr | head -n "$topn" || true)

        sleep 1
        rounds=$((rounds - 1))
    done

    return 1
}

cmd="${1:-}"
case "$cmd" in
  node)
    pick_best_node
    exit $?
    ;;
esac

daemon_flag="--untrusted-daemon"
if [[ "${daemon_mode}" == "trusted" ]]; then
    daemon_flag="--trusted-daemon"
fi

daemon_host=""
daemon_port=""
net_height=""

select_daemon() {
    local selected=""

    tty_print "Starting daemon discovery (Tor + SOCKS proxy)..."
    tty_blank
    selected="$(pick_best_node 2 15 || true)"
    if [[ -z "${selected}" ]]; then
        tty_print "error: failed to select a working daemon"
        return 1
    fi

    read -r daemon_host daemon_port net_height <<<"${selected}"
    if [[ -z "${daemon_host:-}" || -z "${daemon_port:-}" ]]; then
        tty_print "error: failed to select a working daemon"
        return 1
    fi

    tty_print "Using node: ${daemon_host}:${daemon_port}"
    tty_print "Latest block height: ${net_height:-unknown}"
    tty_blank
}

_month_name() {
    case "$1" in
      1)  echo "January" ;;
      2)  echo "February" ;;
      3)  echo "March" ;;
      4)  echo "April" ;;
      5)  echo "May" ;;
      6)  echo "June" ;;
      7)  echo "July" ;;
      8)  echo "August" ;;
      9)  echo "September" ;;
      10) echo "October" ;;
      11) echo "November" ;;
      12) echo "December" ;;
      *)  echo "Month" ;;
    esac
}

run_wallet_process() {
    local rc
    local -a wallet_command=(
        monero-wallet-cli
        --proxy "${proxy}"
        --daemon-host "${daemon_host}"
        --daemon-port "${daemon_port}"
        "${daemon_flag}"
        --log-file /dev/null
        --log-level 0
        "$@"
    )

    set +e
    if tty_ok; then
        "${wallet_command[@]}" </dev/tty >/dev/tty 2>/dev/tty &
    else
        "${wallet_command[@]}" >/dev/null 2>&1 &
    fi
    wallet_pid=$!

    wait "${wallet_pid}"
    rc=$?
    wallet_pid=""
    set -e

    if [[ "${rc}" -eq 130 ]]; then
        on_sigint
    elif [[ "${rc}" -eq 143 ]]; then
        on_sigterm
    fi

    return "$rc"
}

# Run monero-wallet-cli for CREATE/RESTORE with real TTY stdio (no logs)
run_wallet_cli_tty() {
    run_wallet_process "$@"
}

# Screen A — Restore height (ONLY place with explanation)
# stdout: DATE / CUSTOM / ZERO
# return: 0 ok, 2 back
choose_restore_mode() {
    tty_ok || return 2
    local c

    while true; do
        clear_screen

        tty_print "Restore height"
        tty_print "------------------------------------------------------------"
        tty_print "Choose where the wallet should start scanning the blockchain."
        tty_print "A closer starting point = faster sync."
        tty_blank
        tty_print "If you don't know the exact block height, use the date option."
        tty_print "Pick the month/year when you created the wallet or received the first transaction."
        tty_print "If unsure, choose an earlier date (safer, but slower)."
        tty_blank
        tty_print "Seed phrase input:"
        tty_print "- Monero CLI may ask for the seed in 3 parts (it is normal)."
        tty_print "- If your seed is on one line, split it into 3 lines: 8-8-9 words."
        tty_print "------------------------------------------------------------"
        tty_blank

        tty_print "1. Pick a date (fast)"
        tty_print "2. Enter a block height (fast)"
        tty_print "3. Start from 0 (very slow)"
        tty_blank
        tty_print "b. Back"
        tty_blank

        c="$(read_choice "?: ")"
        case "$c" in
          1) printf "%s\n" "DATE"; return 0 ;;
          2) printf "%s\n" "CUSTOM"; return 0 ;;
          3) printf "%s\n" "ZERO"; return 0 ;;
          b|B) return 2 ;;
          *) ;;
        esac
    done
}

# Screen B — Pick a year
# stdout: selected year
# return: 0 ok, 2 back
pick_year() {
    local years_to_show="${1:-12}"
    tty_ok || return 2

    local cy choice i y
    cy="$(date +%Y)"

    while true; do
        clear_screen

        tty_print "Pick a year"
        tty_print "------------------------------------------------------------"
        tty_print "Select the year when you created the wallet or first received funds."
        tty_print "If unsure, choose an earlier year."
        tty_print "------------------------------------------------------------"
        tty_blank

        tty_print "Years:"
        for i in $(seq 1 "$years_to_show"); do
            y=$((cy - (i - 1)))
            if (( i < 10 )); then
                tty_printf "%d.  %d\n" "$i" "$y"
            else
                tty_printf "%d. %d\n" "$i" "$y"
            fi
        done
        tty_blank
        tty_print "b. Back"
        tty_blank

        choice="$(read_choice "?: ")"
        case "$choice" in
          b|B) return 2 ;;
        esac

        [[ "$choice" =~ ^[0-9]+$ ]] || continue
        (( choice >= 1 && choice <= years_to_show )) || continue

        y=$((cy - (choice - 1)))
        printf "%s\n" "$y"
        return 0
    done
}

# Screen C — Pick a month (hide future months in current year)
# stdout: estimated height
# return: 0 ok, 2 back
pick_month_for_year() {
    local sel_year="$1"
    local net_height_in="$2"
    local blocks_per_day=720
    local blocks_per_month=$((blocks_per_day * 30))  # estimate

    tty_ok || return 2
    [[ "$sel_year" =~ ^[0-9]+$ ]] || return 2
    [[ "$net_height_in" =~ ^[0-9]+$ ]] || return 2

    local cy cm max_month choice m h label months_diff
    cy="$(date +%Y)"
    cm="$(date +%m)"; cm="${cm#0}"

    max_month=12
    if (( sel_year == cy )); then
        max_month="$cm"   # hide future months in current year
    fi

    while true; do
        clear_screen

        tty_print "Pick a month"
        tty_print "------------------------------------------------------------"
        tty_print "Choose the month when you created the wallet or first received funds."
        tty_print "If unsure, choose an earlier month."
        tty_print "------------------------------------------------------------"
        tty_blank

        tty_print "${sel_year}/Months:"
        for m in $(seq 1 "$max_month"); do
            months_diff=$(( (cy - sel_year) * 12 + (cm - m) ))
            h=$(( net_height_in - months_diff * blocks_per_month ))
            (( h < 0 )) && h=0
            (( h > net_height_in )) && h="$net_height_in"
            label="$(_month_name "$m")"
            tty_printf "%2d.  %-9s [%s]\n" "$m" "$label" "$h"
        done

        tty_blank
        tty_print "b. Back"
        tty_blank

        choice="$(read_choice "?: ")"
        case "$choice" in
          b|B) return 2 ;;
        esac

        [[ "$choice" =~ ^[0-9]+$ ]] || continue
        (( choice >= 1 && choice <= max_month )) || continue

        months_diff=$(( (cy - sel_year) * 12 + (cm - choice) ))
        h=$(( net_height_in - months_diff * blocks_per_month ))
        (( h < 0 )) && h=0
        (( h > net_height_in )) && h="$net_height_in"
        printf "%s\n" "$h"
        return 0
    done
}

# Screen D1/D2 — Manual restore height (input + confirm)
# stdout: chosen height
# return: 0 ok
manual_restore_height() {
    tty_ok || return 2
    local v c

    while true; do
        # D1 — input (NO "b. Back" here)
        clear_screen
        tty_print "Manual restore height"
        tty_print "------------------------------------------------------------"
        tty_blank
        v="$(read_choice "Restore height (e.g. 5467788): ")"
        v="$(_trim "$v")"
        [[ "$v" =~ ^[0-9]+$ ]] || continue

        # D2 — confirm
        while true; do
            clear_screen
            tty_print "Manual restore height"
            tty_print "------------------------------------------------------------"
            tty_blank
            tty_print "You entered: ${v}"
            tty_blank
            tty_print "b. Back"
            c="$(read_choice "Use this restore height? [y/N]: ")"
            c="$(_trim "$c")"

            case "$c" in
              #b|B) break ;; # back to input
              b|B) return 2 ;;
              y|Y|yes|YES|Yes)
                printf "%s\n" "$v"
                return 0
                ;;
              ""|n|N|no|NO|No)
                break ;; # treat default as "no" -> back to input
              *) ;;
            esac
        done
    done
}

# ---- wallet selection and safe create (no overwrite) ----
wallet_name=""
wallet_dir=""
wallet_file=""
wallet_keys=""

dir_empty() {
    [[ -d "$1" ]] || return 0
    [[ -z "$(ls -A "$1" 2>/dev/null || true)" ]]
}

wallet_name_valid() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]]
}

set_wallet_target() {
    local name="$1"
    wallet_name="${name}"
    wallet_dir="${wallet_root}/${name}"
    wallet_file="${wallet_dir}/${name}"
    wallet_keys="${wallet_file}.keys"
}

wallet_is_complete() {
    local name="$1"
    [[ -f "${wallet_root}/${name}/${name}" &&
       -f "${wallet_root}/${name}/${name}.keys" ]]
}

list_wallet_names() {
    local d name
    for d in "${wallet_root}"/*; do
        [[ -d "${d}" ]] || continue
        name="${d##*/}"
        wallet_name_valid "${name}" || continue
        wallet_is_complete "${name}" || continue
        printf '%s\n' "${name}"
    done | sort
}

choose_existing_wallet() {
    local -a names=()
    local name choice i

    while IFS= read -r name; do
        [[ -n "${name}" ]] && names+=("${name}")
    done < <(list_wallet_names)

    while true; do
        clear_screen
        tty_print "Open existing wallet"
        tty_print "------------------------------------------------------------"
        tty_print "Wallet vault: ${vault_host_path}"
        tty_blank

        if (( ${#names[@]} == 0 )); then
            tty_print "No complete wallets found."
            tty_blank
            read_choice "Press Enter to return... " >/dev/null
            return 2
        fi

        tty_print "Wallets:"
        for ((i = 0; i < ${#names[@]}; i++)); do
            tty_printf "%d.  %s\n" "$((i + 1))" "${names[i]}"
        done
        tty_blank
        tty_print "b. Back"
        tty_blank

        choice="$(read_choice "?: ")"
        case "${choice}" in
          b|B|x|X) return 2 ;;
        esac

        [[ "${choice}" =~ ^[0-9]+$ ]] || continue
        (( choice >= 1 && choice <= ${#names[@]} )) || continue
        set_wallet_target "${names[$((choice - 1))]}"
        return 0
    done
}

prompt_new_wallet() {
    local name

    while true; do
        clear_screen
        tty_print "New wallet"
        tty_print "------------------------------------------------------------"
        tty_print "Enter a name for the wallet."
        tty_print "Allowed: A-Z, a-z, 0-9, _ and -"
        tty_blank
        tty_print "b. Back"
        tty_blank

        name="$(read_choice "Wallet name: ")"
        case "${name}" in
          b|B) return 2 ;;
        esac

        if ! wallet_name_valid "${name}"; then
            tty_print "Invalid wallet name."
            pause_or_enter
            continue
        fi
        if [[ -e "${wallet_root}/${name}" ]]; then
            tty_print "That wallet name already exists or is reserved."
            pause_or_enter
            continue
        fi

        set_wallet_target "${name}"
        return 0
    done
}

create_wallet() {
    local rc

    if [[ -e "${wallet_dir}" ]]; then
        tty_print "refusing to create: wallet directory already exists."
        return 1
    fi
    if ! mkdir -m 700 "${wallet_dir}" 2>/dev/null; then
        tty_print "error: cannot create wallet directory: ${wallet_dir}"
        return 1
    fi

    clear_screen
    vault_dirty=1
    if run_wallet_cli_tty --generate-new-wallet "${wallet_file}"; then
        rc=0
    else
        rc=$?
    fi

    if [[ "${rc}" -eq 0 && -f "${wallet_file}" && -f "${wallet_keys}" ]]; then
        tty_print "wallet created: ${wallet_name}"
        if ! save_vault; then
            pause_or_enter
            return 1
        fi
        pause_or_enter
        return 0
    fi

    tty_print "error: monero-wallet-cli exited with code ${rc}"
    pause_or_enter
    return 1
}

restore_wallet() {
    local mode mrc mrc_custom mrc2 yrc rc
    local sel_year restore_height

    while true; do
        set +e
        mode="$(choose_restore_mode)"
        mrc=$?
        set -e
        if [[ "${mrc}" -eq 2 ]]; then
            return 2
        fi

        if [[ "${mode}" == "ZERO" ]]; then
            clear_screen
            vault_dirty=1
            if run_wallet_cli_tty \
                --restore-deterministic-wallet \
                --restore-height "0" \
                --generate-new-wallet "${wallet_file}"; then
                rc=0
            else
                rc=$?
            fi
            if [[ "${rc}" -eq 0 ]]; then
                tty_print "wallet restored: ${wallet_name}"
                if ! save_vault; then
                    pause_or_enter
                    return 1
                fi
                pause_or_enter
                return 0
            fi
            tty_print "error: monero-wallet-cli exited with code ${rc}"
            pause_or_enter
            continue
        fi

        if [[ "${mode}" == "CUSTOM" ]]; then
            set +e
            restore_height="$(manual_restore_height)"
            mrc_custom=$?
            set -e
            [[ "${mrc_custom}" -eq 2 ]] && continue
            [[ -n "${restore_height:-}" ]] || continue

            clear_screen
            vault_dirty=1
            if run_wallet_cli_tty \
                --restore-deterministic-wallet \
                --restore-height "${restore_height}" \
                --generate-new-wallet "${wallet_file}"; then
                rc=0
            else
                rc=$?
            fi
            if [[ "${rc}" -eq 0 ]]; then
                tty_print "wallet restored: ${wallet_name}"
                if ! save_vault; then
                    pause_or_enter
                    return 1
                fi
                pause_or_enter
                return 0
            fi
            tty_print "error: monero-wallet-cli exited with code ${rc}"
            pause_or_enter
            continue
        fi

        # DATE: Year -> Month -> run
        while true; do
            set +e
            sel_year="$(pick_year 12)"
            yrc=$?
            set -e
            if [[ "${yrc}" -eq 2 ]]; then
                break
            fi

            set +e
            restore_height="$(pick_month_for_year "${sel_year}" "${net_height:-0}")"
            mrc2=$?
            set -e
            if [[ "${mrc2}" -eq 2 ]]; then
                continue
            fi

            clear_screen
            vault_dirty=1
            if run_wallet_cli_tty \
                --restore-deterministic-wallet \
                --restore-height "${restore_height}" \
                --generate-new-wallet "${wallet_file}"; then
                rc=0
            else
                rc=$?
            fi
            if [[ "${rc}" -eq 0 ]]; then
                tty_print "wallet restored: ${wallet_name}"
                if ! save_vault; then
                    pause_or_enter
                    return 1
                fi
                pause_or_enter
                return 0
            fi
            tty_print "error: monero-wallet-cli exited with code ${rc}"
            pause_or_enter
            break
        done
    done
}

run_selected_wallet() {
    local max_attempts=3
    local attempt=1
    local rc

    while true; do
        clear_screen
        tty_print "Wallet: ${wallet_name}"
        tty_print "Daemon: ${daemon_host}:${daemon_port}"
        tty_blank

        set +e
        vault_dirty=1
        run_wallet_process --wallet-file "${wallet_file}" "$@"
        rc=$?
        set -e

        if [[ "${rc}" -eq 0 ]]; then
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ "${attempt}" -gt "${max_attempts}" ]]; then
            clear_screen
            tty_print "error: failed after ${max_attempts} attempts (exit code ${rc})."
            return "${rc}"
        fi

        clear_screen
        tty_print "failed (exit code ${rc}). try again (${attempt}/${max_attempts})..."
        tty_blank
        pause_or_enter
    done
}

if ! tty_ok; then
    # no tty -> do not print prompts into logs
    exit 1
fi

set +e
choose_vault_mode
rc=$?
set -e
if [[ "${rc}" -eq 2 ]]; then
    exit 0
fi
if [[ "${rc}" -ne 0 ]]; then
    exit 1
fi

if ! mkdir -p "${vault_root}" 2>/dev/null; then
    tty_print "error: cannot access temporary vault directory"
    exit 1
fi
if ! open_or_create_vault; then
    clear_wallet_root
    exit 1
fi

while true; do
    clear_screen
    tty_print "Monero wallet launcher"
    tty_print "------------------------------------------------------------"
    tty_print "Wallet vault: ${vault_host_path}"
    tty_print "Unlock mode: ${vault_mode}"
    tty_blank
    tty_print "Choose action:"
    tty_print "1. Open existing wallet"
    tty_print "2. Create NEW wallet"
    tty_print "3. Restore wallet from SEED phrase"
    tty_blank
    tty_print "x. Exit"
    tty_blank

    choice="$(read_choice "?: ")"
    case "${choice}" in
      1)
        set +e
        choose_existing_wallet
        rc=$?
        set -e
        [[ "${rc}" -eq 2 ]] && continue
        [[ "${rc}" -eq 0 ]] || continue

        if select_daemon; then
            if run_selected_wallet "$@"; then
                if ! save_vault; then
                    pause_or_enter
                fi
            else
                rc=$?
                tty_print "wallet session ended with code ${rc}"
                if ! save_vault; then
                    pause_or_enter
                fi
                pause_or_enter
            fi
        else
            pause_or_enter
        fi
        ;;

      2)
        set +e
        prompt_new_wallet
        rc=$?
        set -e
        [[ "${rc}" -eq 2 ]] && continue
        [[ "${rc}" -eq 0 ]] || continue

        if select_daemon; then
            if create_wallet; then
                :
            fi
        else
            pause_or_enter
        fi
        ;;

      3)
        set +e
        prompt_new_wallet
        rc=$?
        set -e
        [[ "${rc}" -eq 2 ]] && continue
        [[ "${rc}" -eq 0 ]] || continue

        if select_daemon; then
            set +e
            restore_wallet
            rc=$?
            set -e
            if [[ "${rc}" -ne 2 && "${rc}" -ne 0 ]]; then
                tty_print "wallet restore ended with code ${rc}"
                pause_or_enter
            fi
        else
            pause_or_enter
        fi
        ;;

      x|X)
        clear_screen
        exit 0
        ;;

      *)
        ;;
    esac
done
