#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=tor-route.sh
source "$(dirname "${BASH_SOURCE[0]}")/tor-route.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp}"' EXIT

sleep() {
    printf '%s\n' "$1" >> "${tmp}/delays"
}

probe() {
    local count
    count="$(cat "${tmp}/attempts")"
    count=$((count + 1))
    printf '%s\n' "${count}" > "${tmp}/attempts"
    case "$1" in
        recover)
            if ((count < 3)); then
                echo 'curl: (28) Operation timed out' >&2
                return 28
            fi
            printf '%s\n' '{"IsTor":true,"IP":"192.0.2.1"}'
            ;;
        false-result) printf '%s\n' '{"IsTor":false,"Other":true}' ;;
        failed-request)
            printf '%s\n' '{"IsTor":true}'
            return 28
            ;;
    esac
}

printf '0\n' > "${tmp}/attempts"
result="$(wait_for_tor_route 4 2 probe recover 2>"${tmp}/errors")"
[[ "${result}" == '{"IsTor":true,"IP":"192.0.2.1"}' ]]
[[ "$(cat "${tmp}/attempts")" == 3 ]]
[[ "$(wc -l < "${tmp}/delays" | tr -d ' ')" == 2 ]]
grep -q 'curl: (28)' "${tmp}/errors"

for scenario in false-result failed-request; do
    printf '0\n' > "${tmp}/attempts"
    : > "${tmp}/delays"
    if wait_for_tor_route 3 2 probe "${scenario}" >"${tmp}/result" 2>"${tmp}/errors"; then
        printf '[error] invalid Tor result accepted: %s\n' "${scenario}" >&2
        exit 1
    fi
    [[ "$(cat "${tmp}/attempts")" == 3 ]]
    [[ "$(wc -l < "${tmp}/delays" | tr -d ' ')" == 2 ]]
    [[ ! -s "${tmp}/result" ]]
done
printf '%s\n' '[ok] Tor route retries recover from timeouts and reject non-Tor or failed requests'
