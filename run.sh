#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
monero_launcher="$project_dir/monero/monero-cli.sh"

clear_menu() {
    [[ -t 1 ]] || return 0
    clear 2>/dev/null || true
}

pause_for_input() {
    printf '%s' 'Press Enter to continue...'
    IFS= read -r _ || true
}

show_main_menu() {
    clear_menu
    printf '%s\n' \
        'mgla' \
        '------------------------------------------------------------' \
        '1. Monero wallet' \
        'q. Exit' \
        '------------------------------------------------------------'
    printf '%s' 'Select a scenario: '
}

while true; do
    show_main_menu

    if ! IFS= read -r choice; then
        printf '\n'
        exit 0
    fi

    case "$choice" in
        1)
            if [[ ! -x "$monero_launcher" ]]; then
                printf '[error] Monero launcher is missing or not executable: %s\n' \
                    "$monero_launcher" >&2
                pause_for_input
                continue
            fi

            printf '\n[info] starting Monero scenario\n'
            if bash "$monero_launcher"; then
                status=0
            else
                status=$?
            fi

            case "$status" in
                0|130|143)
                    ;;
                *)
                    printf '[error] Monero scenario exited with status %d\n' "$status" >&2
                    pause_for_input
                    ;;
            esac
            ;;
        q|Q|0)
            exit 0
            ;;
        *)
            printf '[error] unknown selection: %s\n' "$choice" >&2
            pause_for_input
            ;;
    esac
done
