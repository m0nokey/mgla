#!/usr/bin/env bash
# shellcheck shell=bash

# Shared encrypted-wallet vault lifecycle for every wallet launcher.
#
# A wallet launcher must provide these UI adapters, source this file, and call
# vault_configure with its wallet-specific paths and type:
#   vault_tty_clear, vault_tty_blank, vault_tty_printf,
#   vault_read_choice, vault_pause_or_enter
#
# The adapters are the only wallet-specific part of this module. Password
# handling, session handling, layout migration, and persistence stay here.

vault_root=""
vault_root_expected=""
wallet_root=""
vault_wallet_type=""
vault_binary=""
vault_store=""
vault_host_dir=""
vault_size=""
vault_file=""
vault_host_path=""
vault_loaded=0
vault_dirty=0
vault_layout_migrated=0
vault_mode=""
vault_session_dir=""
vault_session_socket=""
vault_session_pid=""

vault_configure() {
    if [[ "$#" -ne 8 ]]; then
        printf '%s\n' '[error] shared vault configuration requires eight arguments' >&2
        return 2
    fi

    local root="$1" expected_root="$2" wallet="$3" wallet_type="$4"
    local binary="$5" store="$6" host_dir="$7" size="$8"

    vault_root="${root}"
    vault_root_expected="${expected_root}"
    wallet_root="${wallet}"
    vault_wallet_type="${wallet_type}"
    vault_binary="${binary}"
    vault_store="${store}"
    vault_host_dir="${host_dir}"
    vault_size="${size}"
    vault_file=""
    vault_host_path=""
    vault_loaded=0
    vault_dirty=0
    vault_layout_migrated=0
    vault_mode="${MGLA_VAULT_MODE:-}"
    vault_session_dir=""
    vault_session_socket=""
    vault_session_pid=""

    vault_validate_interface
}

vault_validate_interface() {
    local required

    for required in \
        vault_tty_clear vault_tty_blank vault_tty_printf \
        vault_read_choice vault_pause_or_enter; do
        if ! declare -F "${required}" >/dev/null 2>&1; then
            printf '[error] shared vault UI adapter is missing: %s\n' "${required}" >&2
            return 1
        fi
    done

    for required in \
        vault_root vault_root_expected wallet_root vault_wallet_type \
        vault_binary vault_store vault_host_dir vault_size; do
        if [[ -z "${!required+x}" ]]; then
            printf '[error] shared vault variable is missing: %s\n' "${required}" >&2
            return 1
        fi
    done
}

vault_root_path() {
    printf '%s\n' "${vault_root}"
}

vault_wallet_root_path() {
    printf '%s\n' "${wallet_root}"
}

vault_host_file_path() {
    printf '%s\n' "${vault_host_path}"
}

vault_unlock_mode() {
    printf '%s\n' "${vault_mode}"
}

vault_tty_print() {
    vault_tty_printf '%s\n' "${1:-}"
}

vault_with_tty_password() {
    "${vault_binary}" --tty-password "$@"
}

choose_vault_mode() {
    local choice

    case "${vault_mode}" in
        prompt|session)
            return 0
            ;;
    esac

    while true; do
        vault_tty_clear
        vault_tty_print "Vault unlock mode"
        vault_tty_print "------------------------------------------------------------"
        vault_tty_print "Choose how the vault key is held while this launcher is running."
        vault_tty_blank
        vault_tty_print "1. Prompt"
        vault_tty_print "   Ask for the vault password on every open and save."
        vault_tty_print "   The derived key is discarded after each operation."
        vault_tty_blank
        vault_tty_print "2. Session"
        vault_tty_print "   Enter the password once and keep only the derived key"
        vault_tty_print "   in locked memory until the launcher exits."
        vault_tty_blank
        vault_tty_print "b. Back"
        vault_tty_print "x. Exit"
        vault_tty_blank

        if ! vault_read_choice choice "?: "; then
            return 1
        fi
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
    "${vault_binary}" session-request "${vault_session_socket}" "${command}" >/dev/null 2>&1
}

stop_vault_session() {
    local pid="${vault_session_pid:-}"
    local socket="${vault_session_socket:-}"
    local session_dir="${vault_session_dir:-}"
    local i

    if [[ -n "${socket}" && -S "${socket}" ]]; then
        "${vault_binary}" session-request "${socket}" shutdown >/dev/null 2>&1 || true
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
        vault_tty_print "error: cannot create private vault session directory"
        return 1
    fi
    if ! chmod 700 "${vault_session_dir}"; then
        vault_tty_print "error: cannot protect vault session directory"
        stop_vault_session
        return 1
    fi
    vault_session_socket="${vault_session_dir}/vault.sock"

    vault_tty_print "Starting protected vault session..."
    case "${action}" in
        open)
            "${vault_binary}" session-open \
                "${vault_file}" "${vault_root}" "${vault_session_socket}" \
                </dev/tty >/dev/tty 2>/dev/tty &
            ;;
        create)
            "${vault_binary}" session-create-generated \
                "${vault_file}" "${vault_size}" "${vault_root}" \
                "${vault_root}" "${vault_session_socket}" \
                </dev/tty >/dev/tty 2>/dev/tty &
            ;;
        *)
            vault_tty_print "error: invalid vault session action"
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
            vault_tty_print "error: vault session stopped unexpectedly"
            stop_vault_session
            return 1
        fi
        sleep 0.1
    done

    vault_tty_print "error: vault session did not start"
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
    local marker="" legacy_kind="" known_kind

    vault_layout_migrated=0

    # A vault belongs to one wallet type. Refuse a valid vault from another
    # wallet instead of silently creating an empty wallet beside its data.
    if [[ -d "${vault_root}/${vault_wallet_type}" ]]; then
        for known_kind in monero bitcoin; do
            if [[ "${known_kind}" != "${vault_wallet_type}" &&
                  -e "${vault_root}/${known_kind}" ]]; then
                return 1
            fi
        done
        return 0
    fi
    for known_kind in monero bitcoin; do
        if [[ "${known_kind}" != "${vault_wallet_type}" &&
              -d "${vault_root}/${known_kind}" ]]; then
            return 1
        fi
    done

    if [[ -f "${vault_root}/.mgla-wallet-type" ]]; then
        IFS= read -r marker < "${vault_root}/.mgla-wallet-type" || true
        if [[ -n "${marker}" && "${marker}" != "${vault_wallet_type}" ]]; then
            return 1
        fi
        legacy_kind="${marker}"
    fi
    if [[ -z "${legacy_kind}" ]] && legacy_monero_layout; then
        legacy_kind="monero"
    fi
    if [[ -z "${legacy_kind}" &&
          ( -d "${vault_root}/wallets" || -f "${vault_root}/config" ) ]]; then
        legacy_kind="bitcoin"
    fi

    if [[ -n "${legacy_kind}" ]]; then
        [[ "${legacy_kind}" == "${vault_wallet_type}" ]] || return 1
        if ! move_legacy_vault_entries "${vault_root}/${vault_wallet_type}"; then
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

    vault_tty_print "Saving encrypted wallet vault..."
    if [[ "${vault_mode}" == "session" ]]; then
        if vault_session_request pack; then
            saved=1
        fi
    elif vault_with_tty_password pack "${vault_file}" "${vault_root}"; then
        saved=1
    fi

    if [[ "${saved}" -eq 1 ]]; then
        vault_dirty=0
        vault_tty_print "[ok] encrypted wallet vault saved"
        return 0
    fi

    vault_tty_print "[error] failed to save encrypted wallet vault"
    return 1
}

vault_mark_dirty() {
    vault_dirty=1
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
        vault_tty_clear
        vault_tty_print "Create encrypted wallet vault"
        vault_tty_print "------------------------------------------------------------"
        vault_tty_print "Enter a short name for the vault."
        vault_tty_print "The .mgla extension is added automatically."
        vault_tty_print "Allowed: A-Z, a-z, 0-9, ., _ and -"
        vault_tty_blank
        vault_tty_print "b. Back"
        vault_tty_blank

        if ! vault_read_choice name "Vault name: "; then
            return 1
        fi
        case "${name}" in
          b|B) return 2 ;;
        esac

        [[ -n "${name}" ]] || continue
        if [[ "${name}" != *.mgla ]]; then
            name="${name}.mgla"
        fi

        if ! vault_name_valid "${name}"; then
            vault_tty_print "Invalid vault name."
            vault_pause_or_enter
            continue
        fi
        if [[ -e "${vault_store}/${name}" ]]; then
            vault_tty_print "That vault name already exists or is reserved."
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
        vault_tty_clear
        vault_tty_print "Wallet vaults"
        vault_tty_print "------------------------------------------------------------"
        vault_tty_print "Vault directory: ${vault_host_dir}"
        vault_tty_blank

        if (( ${#names[@]} == 0 )); then
            vault_tty_print "No encrypted vaults found."
        else
            vault_tty_print "Vaults:"
            for ((i = 0; i < ${#names[@]}; i++)); do
                vault_tty_printf "%d.  %s\n" "$((i + 1))" "${names[i]}"
            done
        fi

        vault_tty_blank
        vault_tty_print "n. Create new vault"
        vault_tty_print "x. Exit"
        vault_tty_blank

        if ! vault_read_choice choice "?: "; then
            return 1
        fi
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
    local choice rc

    if [[ ! -x "${vault_binary}" ]]; then
        vault_tty_print "error: vault binary is missing"
        return 1
    fi
    if ! mkdir -p "${vault_store}" 2>/dev/null || ! chmod 700 "${vault_store}" 2>/dev/null; then
        vault_tty_print "error: cannot access host vault directory"
        return 1
    fi
    if ! mkdir -p "${vault_root}" 2>/dev/null || ! chmod 700 "${vault_root}" 2>/dev/null; then
        vault_tty_print "error: cannot access temporary vault directory"
        return 1
    fi
    if ! choose_vault; then
        return 1
    fi

    if [[ -f "${vault_file}" ]]; then
        while true; do
            vault_tty_clear
            vault_tty_print "Open encrypted wallet vault"
            vault_tty_print "------------------------------------------------------------"
            vault_tty_print "Vault file: ${vault_host_path}"
            vault_tty_blank

            if [[ "${vault_mode}" == "session" ]]; then
                if start_vault_session open && vault_session_request unpack; then
                    if ! normalize_vault_layout || ! ensure_wallet_root; then
                        stop_vault_session
                        clear_wallet_root
                        vault_tty_print "error: unrecognized wallet vault layout"
                        return 1
                    fi
                    vault_loaded=1
                    vault_dirty="${vault_layout_migrated}"
                    vault_tty_print "[ok] encrypted wallet vault opened"
                    return 0
                fi
                stop_vault_session
            elif vault_with_tty_password unpack "${vault_file}" "${vault_root}"; then
                if ! normalize_vault_layout || ! ensure_wallet_root; then
                    clear_wallet_root
                    vault_tty_print "error: unrecognized wallet vault layout"
                    return 1
                fi
                vault_loaded=1
                vault_dirty="${vault_layout_migrated}"
                vault_tty_print "[ok] encrypted wallet vault opened"
                return 0
            fi

            clear_wallet_root
            vault_tty_print "error: wrong password or damaged vault"
            vault_tty_blank
            if ! vault_read_choice choice "Press Enter to try again, or x to exit: "; then
                return 1
            fi
            [[ "${choice}" =~ ^[xX]$ ]] && return 1
        done
    fi

    vault_tty_clear
    vault_tty_print "Create encrypted wallet vault"
    vault_tty_print "------------------------------------------------------------"
    vault_tty_print "No vault found at: ${vault_host_path}"
    vault_tty_print "A fixed-size ${vault_size} vault will be created."
    vault_tty_blank
    vault_tty_print "A random password will be shown once. Save it offline."
    vault_tty_print "If it is lost, the vault cannot be opened again."
    vault_tty_print "Wallet seed phrases can restore wallets, but not local wallet data."
    vault_tty_blank

    if ! ensure_wallet_root; then
        vault_tty_print "error: cannot initialize wallet directory"
        return 1
    fi
    if [[ "${vault_mode}" == "session" ]]; then
        if start_vault_session create; then
            vault_loaded=1
            vault_dirty=0
            vault_tty_print "[ok] encrypted wallet vault created"
            return 0
        fi
        vault_tty_print "error: failed to create encrypted wallet vault"
        return 1
    fi

    if "${vault_binary}" create-generated "${vault_file}" "${vault_size}" "${vault_root}"; then
        vault_loaded=1
        vault_dirty=0
        vault_tty_print "[ok] encrypted wallet vault created"
        return 0
    else
        rc=$?
        if [[ "${rc}" -eq 2 ]]; then
            return 1
        fi
        vault_tty_print "error: failed to create encrypted wallet vault"
        return 1
    fi
}
