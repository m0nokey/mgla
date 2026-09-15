#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

: "${HOME:?HOME is required}"

module_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project="mgla"
compose_file="${module_dir}/compose.yaml"
workdir="$(mktemp -d -t "${project}.bitcoin.XXXXXXXX")"
wallet_store_host_dir="${BITCOIN_WALLET_STORE_HOST_DIR:-${WALLET_STORE_HOST_DIR:-${HOME}/.mgla/bitcoin}}"

alpine_version="${ALPINE_VERSION:-3.24}"
electrum_version="${ELECTRUM_VERSION:-4.8.2}"
electrum_archive_sha256="${ELECTRUM_ARCHIVE_SHA256:-f38cee333c866986cdfb304428fa7487affc429c3853fc80e9822bd420bbc229}"
image_mode="${IMAGE_MODE-pull}"
image_registry="${IMAGE_REGISTRY-ghcr.io/m0nokey}"
image_tag="${IMAGE_TAG-latest}"

info() {
    printf '[info] %s\n' "${*}"
}

warn() {
    printf '[warn] %s\n' "${*}"
}

error() {
    printf '[error] %s\n' "${*}" >&2
}

die() {
    error "${*}"
    exit 1
}

if [[ "${wallet_store_host_dir}" != /* ]]; then
    die 'BITCOIN_WALLET_STORE_HOST_DIR must be an absolute path'
fi

if [[ ! "${alpine_version}" =~ ^3\.24$ ]]; then
    die "Alpine version must be exactly 3.24: ${alpine_version}"
fi

if [[ ! "${electrum_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "invalid Electrum version: ${electrum_version}"
fi

if [[ ! "${electrum_archive_sha256}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    die 'ELECTRUM_ARCHIVE_SHA256 must be a 64-character hexadecimal SHA-256 digest'
fi

case "${image_mode}" in
    pull|build)
        ;;
    *)
        die 'IMAGE_MODE must be either pull or build'
        ;;
esac

if [[ -n "${image_registry}" && ! "${image_registry}" =~ ^[[:alnum:]][[:alnum:]./_-]*$ ]]; then
    die "invalid IMAGE_REGISTRY: ${image_registry}"
fi

if [[ ! "${image_tag}" =~ ^[[:alnum:]_][[:alnum:]._-]{0,127}$ ]]; then
    die "invalid IMAGE_TAG: ${image_tag}"
fi

image_registry="${image_registry%/}"
image_prefix="mgla"
if [[ -n "${image_registry}" ]]; then
    image_prefix="${image_registry}/mgla"
fi

exit_image="${image_prefix}-exit:${image_tag}"
haproxy_image="${image_prefix}-haproxy:${image_tag}"
bitcoin_image="${image_prefix}-bitcoin:${image_tag}"

exit_a_container="mgla-exit-a"
exit_b_container="mgla-exit-b"
haproxy_container="mgla-haproxy"
bitcoin_container="mgla-bitcoin"
bitcoin_container_uid=""
bitcoin_container_gid=""

container_names=(
    "${exit_a_container}"
    "${exit_b_container}"
    "${haproxy_container}"
    "${bitcoin_container}"
)

legacy_project="tor_alpine_monero_test"
legacy_container_names=(
    "tor_monero_test_exit_a"
    "tor_monero_test_exit_b"
    "tor_monero_test_haproxy"
    "tor_monero_test_app"
    "tor_monero_test_client"
)
cleanup_container_names=("${container_names[@]}" "${legacy_container_names[@]}")

ext_network_container_subnet_cidr_ipv4=""
ext_network_container_gateway_ipv4=""
ext_network_container_exit_a_ipv4=""
ext_network_container_exit_b_ipv4=""
int_network_container_subnet_cidr_ipv4=""
int_network_container_gateway_ipv4=""
int_network_container_exit_a_ipv4=""
int_network_container_exit_b_ipv4=""
int_network_container_haproxy_ipv4=""
int_network_container_bitcoin_ipv4=""
guard_pid=""

compose() {
    docker compose -p "${project}" -f "${compose_file}" "$@"
}

need() {
    command -v "${1}" >/dev/null 2>&1 || die "missing command: ${1}"
}

set_container_identity() {
    local uid gid

    uid="$(id -u)"
    gid="$(id -g)"
    if [[ ! "${uid}" =~ ^[1-9][0-9]*$ || ! "${gid}" =~ ^[1-9][0-9]*$ ]]; then
        die 'the launcher must run as a non-root user'
    fi
    bitcoin_container_uid="${uid}"
    bitcoin_container_gid="${gid}"
}

docker_subnets() {
    local ids id
    local -a id_array=()

    ids="$(docker network ls -q 2>/dev/null || true)"
    [[ -n "${ids}" ]] || return 0

    while IFS= read -r id; do
        [[ -n "${id}" ]] && id_array+=("${id}")
    done <<< "${ids}"

    ((${#id_array[@]} > 0)) || return 0
    docker network inspect "${id_array[@]}" \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null |
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || true
}

cidr_overlaps() {
    local first="${1}" second="${2}"

    awk -v first="${first}" -v second="${second}" '
        function ip_to_int(ip, octets) {
            split(ip, octets, ".")
            return octets[1] * 16777216 + octets[2] * 65536 +
                octets[3] * 256 + octets[4]
        }
        function cidr_range(cidr, fields, ip, prefix, block, value, start, end) {
            split(cidr, fields, "/")
            ip = fields[1]
            prefix = fields[2] + 0
            block = 2 ^ (32 - prefix)
            value = ip_to_int(ip)
            start = int(value / block) * block
            end = start + block - 1
            return start ":" end
        }
        BEGIN {
            split(cidr_range(first), a, ":")
            split(cidr_range(second), b, ":")
            exit((a[2] < b[1] || a[1] > b[2]) ? 1 : 0)
        }
    '
}

subnet_free() {
    local candidate="${1}" subnet

    while IFS= read -r subnet; do
        [[ -z "${subnet}" ]] && continue
        if cidr_overlaps "${candidate}" "${subnet}"; then
            return 1
        fi
    done < <(docker_subnets)

    return 0
}

random_octet() {
    local minimum="${1:-0}" maximum="${2:-255}"
    local range=$((maximum - minimum + 1))
    local value=$((RANDOM % range))

    printf '%d' $((value + minimum))
}

generate_networks() {
    local mask=29
    local ext_second ext_third int_second int_third
    local found=0
    local attempt

    for ((attempt = 1; attempt <= 512; attempt++)); do
        ext_second="$(random_octet 19 119)"
        ext_third="$(random_octet 0 255)"
        ext_network_container_subnet_cidr_ipv4="10.${ext_second}.${ext_third}.0/${mask}"
        if subnet_free "${ext_network_container_subnet_cidr_ipv4}"; then
            found=1
            break
        fi
    done
    ((found == 1)) || die 'could not find a free Docker external subnet'

    ext_network_container_gateway_ipv4="10.${ext_second}.${ext_third}.1"
    ext_network_container_exit_a_ipv4="10.${ext_second}.${ext_third}.2"
    ext_network_container_exit_b_ipv4="10.${ext_second}.${ext_third}.3"

    found=0
    for ((attempt = 1; attempt <= 512; attempt++)); do
        int_second="$(random_octet 121 221)"
        int_third="$(random_octet 0 255)"
        int_network_container_subnet_cidr_ipv4="10.${int_second}.${int_third}.0/${mask}"
        if subnet_free "${int_network_container_subnet_cidr_ipv4}"; then
            found=1
            break
        fi
    done
    ((found == 1)) || die 'could not find a free Docker internal subnet'

    int_network_container_gateway_ipv4="10.${int_second}.${int_third}.1"
    int_network_container_exit_a_ipv4="10.${int_second}.${int_third}.2"
    int_network_container_exit_b_ipv4="10.${int_second}.${int_third}.3"
    int_network_container_haproxy_ipv4="10.${int_second}.${int_third}.4"
    int_network_container_bitcoin_ipv4="10.${int_second}.${int_third}.5"
}

cleanup_stack() {
    set +e

    if command -v docker >/dev/null 2>&1; then
        if [[ -n "${ext_network_container_subnet_cidr_ipv4:-}" ]]; then
            docker compose -p "${project}" -f "${compose_file}" down \
                --volumes --remove-orphans >/dev/null 2>&1 || true
        fi

        for name in "${cleanup_container_names[@]}"; do
            docker rm -f "${name}" >/dev/null 2>&1 || true
        done

        docker network rm \
            "${project}_external_network" \
            "${project}_internal_network" \
            "${legacy_project}_external_network" \
            "${legacy_project}_internal_network" >/dev/null 2>&1 || true

        docker volume rm -f \
            "${project}_exit_a_run" \
            "${project}_exit_b_run" \
            "${legacy_project}_exit_a_run" \
            "${legacy_project}_exit_b_run" >/dev/null 2>&1 || true
    fi

    set -e
}

start_guard() {
    local parent_pid="$$"

    (
        while kill -0 "${parent_pid}" >/dev/null 2>&1; do
            sleep 1
        done
        cleanup_stack
    ) >/dev/null 2>&1 &
    guard_pid="$!"
}

stop_guard() {
    if [[ -n "${guard_pid:-}" ]]; then
        kill -TERM "${guard_pid}" >/dev/null 2>&1 || true
        wait "${guard_pid}" >/dev/null 2>&1 || true
        guard_pid=""
    fi
}

cleanup() {
    set +e
    stop_guard
    cleanup_stack
    rm -rf -- "${workdir}" >/dev/null 2>&1 || true
    set -e
}

on_signal() {
    printf '\n'
    warn 'interrupted, cleaning up...'
    exit 130
}

print_nyx_hint() {
    printf '%s\n' \
        '[info] Tor monitoring is available through Nyx in a second terminal:' \
        "       docker exec -it ${exit_a_container} sh -lc 'nyx --socket /run/tor/control.sock'" \
        "       docker exec -it ${exit_b_container} sh -lc 'nyx --socket /run/tor/control.sock'"
}

print_diagnostics() {
    local name

    printf '%s\n' '[diagnostics] container state'
    docker ps -a --filter 'name=^mgla-' \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' || true

    for name in "${exit_a_container}" "${exit_b_container}" \
        "${haproxy_container}" "${bitcoin_container}"; do
        printf '[diagnostics] %s\n' "${name}"
        docker inspect -f \
            '{{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "${name}" 2>/dev/null || true
    done
}

wait_for_exit() {
    local status_a status_b winner=""
    local seconds

    info 'waiting for at least one Tor exit to become healthy'
    for ((seconds = 1; seconds <= 420; seconds++)); do
        status_a="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${exit_a_container}" 2>/dev/null || true)"
        status_b="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${exit_b_container}" 2>/dev/null || true)"

        if [[ "${status_a}" == healthy ]]; then
            winner="${exit_a_container}"
            break
        fi
        if [[ "${status_b}" == healthy ]]; then
            winner="${exit_b_container}"
            break
        fi

        if ((seconds % 30 == 0)); then
            info "waiting... ${seconds}s exit_a=${status_a:-unknown} exit_b=${status_b:-unknown}"
        fi
        sleep 1
    done

    if [[ -z "${winner}" ]]; then
        error 'neither Tor exit became healthy'
        print_diagnostics >&2
        return 1
    fi

    info "Tor exit ready: ${winner}"
}

wait_for_proxy() {
    local response seconds

    info 'waiting for HAProxy to accept a Tor connection'
    for ((seconds = 1; seconds <= 60; seconds++)); do
        response="$(docker exec "${bitcoin_container}" curl -fsS --max-time 4 \
            --proxy "socks5h://${int_network_container_haproxy_ipv4}:9095" \
            https://check.torproject.org/api/ip 2>/dev/null || true)"

        if printf '%s\n' "${response}" |
            grep -Eq '"IsTor"[[:space:]]*:[[:space:]]*true'; then
            info "HAProxy backend ready after ${seconds}s"
            return 0
        fi

        if ((seconds % 10 == 0)); then
            info "waiting... ${seconds}s HAProxy backend=starting"
        fi
        sleep 1
    done

    error 'HAProxy did not provide a working Tor route'
    print_diagnostics >&2
    return 1
}

run_network_tests() {
    local direct_result tor_result

    info 'running internal network checks'
    printf '%s\n' '[test] direct Internet must be blocked from internal network'
    direct_result="$(docker exec "${bitcoin_container}" curl -fsS --max-time 8 \
        https://check.torproject.org/api/ip 2>/dev/null || true)"
    if [[ -n "${direct_result}" ]]; then
        error 'direct Internet unexpectedly succeeded'
        printf '%s\n' "${direct_result}" >&2
        return 1
    fi
    printf '%s\n' '[ok] direct curl blocked'

    printf '%s\n' '[test] Tor through HAProxy SOCKS5h must work'
    tor_result="$(docker exec "${bitcoin_container}" curl -fsS --max-time 15 \
        --proxy "socks5h://${int_network_container_haproxy_ipv4}:9095" \
        https://check.torproject.org/api/ip 2>/dev/null || true)"
    if ! printf '%s\n' "${tor_result}" |
        grep -Eq '"IsTor"[[:space:]]*:[[:space:]]*true'; then
        error 'Tor SOCKS5h through HAProxy failed'
        printf '%s\n' "${tor_result}" >&2
        return 1
    fi
    printf '%s\n' "${tor_result}"
    printf '%s\n' '[ok] Tor SOCKS5h via HAProxy works'
}

run_electrum_checks() {
    local version

    info 'checking verified Electrum CLI'
    version="$(docker exec "${bitcoin_container}" /opt/venv/bin/electrum \
        --offline --version 2>/dev/null || true)"
    [[ -n "${version}" ]] || {
        error 'verified Electrum binary is not runnable'
        return 1
    }
    printf '%s\n' "${version}" | head -n 1

    info 'checking strict wallet input validation'
    docker exec -e MGLA_VALIDATE_ONLY=1 "${bitcoin_container}" /opt/app/bitcoin

    info 'checking official onion server discovery'
    docker exec -e MGLA_CI=1 "${bitcoin_container}" /opt/app/bitcoin
    printf '%s\n' '[ok] Electrum onion discovery and wallet runtime checks passed'
}

export_runtime_config() {
    export project
    export exit_a_container exit_b_container haproxy_container bitcoin_container
    export exit_image haproxy_image bitcoin_image
    export alpine_version electrum_version electrum_archive_sha256
    export wallet_store_host_dir
    export bitcoin_container_uid bitcoin_container_gid
    export ext_network_container_subnet_cidr_ipv4
    export ext_network_container_gateway_ipv4
    export ext_network_container_exit_a_ipv4
    export ext_network_container_exit_b_ipv4
    export int_network_container_subnet_cidr_ipv4
    export int_network_container_gateway_ipv4
    export int_network_container_exit_a_ipv4
    export int_network_container_exit_b_ipv4
    export int_network_container_haproxy_ipv4
    export int_network_container_bitcoin_ipv4
}

main() {
    trap cleanup EXIT
    trap on_signal INT TERM HUP QUIT

    need docker
    docker compose version >/dev/null 2>&1 ||
        die 'Docker Compose v2 is required'

    info "workdir: ${workdir}"
    info 'preclean old test stack'
    cleanup_stack

    generate_networks
    set_container_identity
    export_runtime_config

    info "external network: ${ext_network_container_subnet_cidr_ipv4}"
    info "internal network: ${int_network_container_subnet_cidr_ipv4}"
    info "Alpine: ${alpine_version}"
    info "Electrum release: ${electrum_version}"
    info "image mode: ${image_mode}"
    info "image tag: ${image_tag}"
    info "wallet directory: ${wallet_store_host_dir}"

    start_guard
    install -d -m 0700 "${wallet_store_host_dir}"

    if [[ "${image_mode}" == pull ]]; then
        info 'pulling published multi-architecture images'
        compose pull
    else
        info 'building Alpine Tor, HAProxy, and Electrum images'
        if [[ "${NO_CACHE:-0}" == 1 ]]; then
            compose build --pull --no-cache
        else
            compose build --pull
        fi
    fi

    info 'starting containers'
    compose up -d --force-recreate --no-build
    print_nyx_hint

    wait_for_exit
    wait_for_proxy
    run_network_tests
    run_electrum_checks

    if [[ "${CI:-0}" == 1 || "${SKIP_WALLET_MENU:-0}" == 1 ]]; then
        info 'CI mode enabled; wallet menu skipped'
        return 0
    fi

    info 'starting Bitcoin wallet menu (Electrum uses Tor-only onion transport)'
    local -a docker_exec_flags=(-i)
    if [[ -t 0 && -t 1 ]]; then
        docker_exec_flags=(-it)
    fi
    docker exec "${docker_exec_flags[@]}" "${bitcoin_container}" /opt/app/bitcoin
}

main "$@"
