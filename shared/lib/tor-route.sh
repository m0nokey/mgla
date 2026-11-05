#!/usr/bin/env bash

# Retry the end-to-end probe: a bootstrapped Tor process alone does not prove
# that HAProxy has selected a usable circuit. The caller bounds each request.
wait_for_tor_route() {
    local max_attempts="${1:?attempt count is required}"
    local retry_delay="${2:?retry delay is required}"
    shift 2
    local attempt response status

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if response="$("$@" 2>&1)"; then
            status=0
        else
            status=$?
        fi
        if ((status == 0)) && printf '%s\n' "${response}" |
            grep -Eq '"IsTor"[[:space:]]*:[[:space:]]*true[[:space:]]*[,}]'; then
            printf '%s\n' "${response}"
            return 0
        fi
        printf '[warn] Tor route attempt %d/%d failed (exit=%d)\n' \
            "${attempt}" "${max_attempts}" "${status}" >&2
        if [[ -n "${response}" ]]; then
            printf '%s\n' "${response:0:512}" >&2
        fi
        if ((attempt < max_attempts)); then
            sleep "${retry_delay}"
        fi
    done
    return 1
}
