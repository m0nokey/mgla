#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# shellcheck source=launcher.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/launcher.sh"

unexpected_output=0
vault_tty_printf() {
    unexpected_output=$((unexpected_output + 1))
}

vault_loaded=1
vault_dirty=1
vault_output_quiet=0
save_attempts=0
save_vault() {
    save_attempts=$((save_attempts + 1))
    vault_tty_print 'internal save diagnostic'
    if ((save_attempts == 1)); then
        return 1
    fi
    vault_dirty=0
}

vault_save_until_clean_quiet
[[ "${save_attempts}" -eq 2 ]]
[[ "${unexpected_output}" -eq 0 ]]
[[ "${vault_output_quiet}" -eq 0 ]]

source "$(dirname "${BASH_SOURCE[0]}")/launcher.sh"
vault_tty_printf() {
    :
}
vault_loaded=1
vault_dirty=1
vault_mode=prompt
runtime_cleanup_calls=0
password_pack_calls=0
vault_remove_runtime_sockets() {
    runtime_cleanup_calls=$((runtime_cleanup_calls + 1))
}
vault_with_tty_password() {
    password_pack_calls=$((password_pack_calls + 1))
}

save_vault
[[ "${runtime_cleanup_calls}" -eq 1 ]]
[[ "${password_pack_calls}" -eq 1 ]]
[[ "${vault_dirty}" -eq 0 ]]

printf '%s\n' '[ok] shared vault launcher lifecycle tests passed'
