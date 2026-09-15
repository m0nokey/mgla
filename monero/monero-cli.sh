#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

module_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

project="mgla"
workdir="$(mktemp -d -t "${project}.XXXXXXXX")"
wallet_store_host_dir="${WALLET_STORE_HOST_DIR:-${WALLET_HOST_DIR:-${HOME}/Downloads/Monero}}"
wallet_vault_name="${WALLET_VAULT_NAME:-wallets.mgla}"
wallet_vault_size="${WALLET_VAULT_SIZE:-128M}"

if [[ "${wallet_store_host_dir}" != /* ]]; then
    echo "[error] WALLET_STORE_HOST_DIR must be an absolute path" >&2
    exit 1
fi
if [[ ! "${wallet_vault_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "${wallet_vault_name}" == *. ]]; then
    echo "[error] WALLET_VAULT_NAME must be a simple filename" >&2
    exit 1
fi
if [[ ! "${wallet_vault_size}" =~ ^[0-9]+[KMGkmg]?$ ]]; then
    echo "[error] WALLET_VAULT_SIZE must be a size such as 128M" >&2
    exit 1
fi
wallet_vault_host_path="${wallet_store_host_dir}/${wallet_vault_name}"

image_mode="${IMAGE_MODE-pull}"
image_registry="${IMAGE_REGISTRY-ghcr.io/m0nokey}"
image_tag="${IMAGE_TAG-latest}"

case "${image_mode}" in
    pull|build) ;;
    *)
        echo "[error] IMAGE_MODE must be either pull or build" >&2
        exit 1
        ;;
esac
if [[ -n "${image_registry}" && ! "${image_registry}" =~ ^[[:alnum:]][[:alnum:]./_-]*$ ]]; then
    echo "[error] invalid IMAGE_REGISTRY: ${image_registry}" >&2
    exit 1
fi
if [[ ! "${image_tag}" =~ ^[[:alnum:]_][[:alnum:]._-]{0,127}$ ]]; then
    echo "[error] invalid IMAGE_TAG: ${image_tag}" >&2
    exit 1
fi
image_registry="${image_registry%/}"
image_prefix="${project}"
if [[ -n "${image_registry}" ]]; then
    image_prefix="${image_registry}/${project}"
fi
exit_image="${image_prefix}-exit:${image_tag}"
haproxy_image="${image_prefix}-haproxy:${image_tag}"
monero_image="${image_prefix}-monero:${image_tag}"

wipe_host() {
    [[ -t 1 ]] || return 0
    clear 2>/dev/null || true
}


exit_a_container="mgla-exit-a"
exit_b_container="mgla-exit-b"
haproxy_container="mgla-haproxy"
monero_container="mgla-monero"
container_names=(
    "${exit_a_container}"
    "${exit_b_container}"
    "${haproxy_container}"
    "${monero_container}"
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
int_network_container_app_ipv4=""

compose_file="${module_dir}/compose.yaml"
guard_pid=""

compose() {
    docker compose -p "${project}" -f "${compose_file}" "$@"
}

rand_u8() {
    local min=${1:-0} max=${2:-255}
    local range=$((max - min + 1))
    local r=$(( (RANDOM << 15) ^ RANDOM ))
    printf '%d' $(( (r % range) + min ))
}

docker_subnets() {
    local ids
    ids="$(docker network ls -q 2>/dev/null)" || return 0
    [[ -z "${ids}" ]] && return 0
    docker network inspect ${ids} \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || true
}

cidr_overlaps() {
    local first="$1" second="$2"
    awk -v A="${first}" -v B="${second}" '
    function ip_to_int(ip, octet) {
        split(ip, octet, ".")
        return octet[1] * 16777216 + octet[2] * 65536 + octet[3] * 256 + octet[4]
    }
    function range(cidr, fields, ip, prefix, block, value, start, end) {
        split(cidr, fields, "/")
        ip = fields[1]
        prefix = fields[2] + 0
        if (!prefix) prefix = 32
        block = 2 ^ (32 - prefix)
        value = ip_to_int(ip)
        start = int(value / block) * block
        end = start + block - 1
        return start ":" end
    }
    BEGIN {
        split(range(A), a, ":")
        split(range(B), b, ":")
        exit((a[2] < b[1] || a[1] > b[2]) ? 1 : 0)
    }'
}

subnet_free_docker() {
    local candidate="$1" subnet
    while read -r subnet; do
        [[ -z "${subnet}" ]] && continue
        cidr_overlaps "${candidate}" "${subnet}" && return 1
    done < <(docker_subnets)
    return 0
}

gen_docker_networks() {
    local mask="${1:-29}"
    local ext_b ext_c int_b int_c

    # Keep the external and internal ranges apart, as in the original Monero
    # scenario, while avoiding every subnet already known to Docker.
    while :; do
        ext_b="$(rand_u8 19 119)"
        ext_c="$(rand_u8 0 255)"
        ext_network_container_subnet_cidr_ipv4="10.${ext_b}.${ext_c}.0/${mask}"
        subnet_free_docker "${ext_network_container_subnet_cidr_ipv4}" && break
    done
    ext_network_container_gateway_ipv4="10.${ext_b}.${ext_c}.1"
    ext_network_container_exit_a_ipv4="10.${ext_b}.${ext_c}.2"
    ext_network_container_exit_b_ipv4="10.${ext_b}.${ext_c}.3"

    while :; do
        int_b="$(rand_u8 121 221)"
        int_c="$(rand_u8 0 255)"
        int_network_container_subnet_cidr_ipv4="10.${int_b}.${int_c}.0/${mask}"
        subnet_free_docker "${int_network_container_subnet_cidr_ipv4}" && break
    done
    int_network_container_gateway_ipv4="10.${int_b}.${int_c}.1"
    int_network_container_exit_a_ipv4="10.${int_b}.${int_c}.2"
    int_network_container_exit_b_ipv4="10.${int_b}.${int_c}.3"
    int_network_container_haproxy_ipv4="10.${int_b}.${int_c}.4"
    int_network_container_app_ipv4="10.${int_b}.${int_c}.5"
}

cleanup_project() {
    set +e
    if command -v docker >/dev/null 2>&1; then
        if [[ -f "${compose_file}" ]]; then
            docker compose -p "${project}" -f "${compose_file}" down --volumes --remove-orphans >/dev/null 2>&1 || true
        fi
        for name in "${cleanup_container_names[@]}"; do
            docker rm -f "${name}" >/dev/null 2>&1 || true
        done
        docker network rm "${project}_external_network" "${project}_internal_network" "${legacy_project}_external_network" "${legacy_project}_internal_network" >/dev/null 2>&1 || true
        docker volume rm -f "${project}_exit_a_run" "${project}_exit_b_run" "${legacy_project}_exit_a_run" "${legacy_project}_exit_b_run" >/dev/null 2>&1 || true
    fi
    set -e
}

start_guard() {
    local guard="${workdir}/._guard.sh"
    cat > "${guard}" <<'EOS'
#!/bin/sh
set +e
project="$1"
compose_file="$2"
parent="$3"
containers_str="${4:-}"
while kill -0 "${parent}" >/dev/null 2>&1; do
    sleep 1
done
if command -v docker >/dev/null 2>&1; then
    docker compose -p "${project}" -f "${compose_file}" down --volumes --remove-orphans >/dev/null 2>&1 || true
    for name in ${containers_str}; do
        docker rm -f "${name}" >/dev/null 2>&1 || true
    done
    docker network rm "${project}_external_network" "${project}_internal_network" >/dev/null 2>&1 || true
    docker volume rm -f "${project}_exit_a_run" "${project}_exit_b_run" >/dev/null 2>&1 || true
fi
EOS
    chmod +x "${guard}"
    if command -v setsid >/dev/null 2>&1; then
        setsid sh "${guard}" "${project}" "${compose_file}" "$$" "${cleanup_container_names[*]}" >/dev/null 2>&1 &
    else
        nohup sh "${guard}" "${project}" "${compose_file}" "$$" "${cleanup_container_names[*]}" >/dev/null 2>&1 &
    fi
    guard_pid="$!"
}

stop_guard() {
    [[ -n "${guard_pid:-}" ]] || return 0
    kill -TERM "${guard_pid}" >/dev/null 2>&1 || true
    wait "${guard_pid}" >/dev/null 2>&1 || true
    guard_pid=""
}

cleanup() {
    set +e
    stop_guard
    if command -v docker >/dev/null 2>&1; then
        if [[ -f "${compose_file}" ]]; then
            docker compose -p "${project}" -f "${compose_file}" down --volumes --remove-orphans >/dev/null 2>&1 || true
        fi
        for name in "${cleanup_container_names[@]}"; do
            docker rm -f "${name}" >/dev/null 2>&1 || true
        done
        docker network rm "${project}_external_network" "${project}_internal_network" "${legacy_project}_external_network" "${legacy_project}_internal_network" >/dev/null 2>&1 || true
        docker volume rm -f "${project}_exit_a_run" "${project}_exit_b_run" "${legacy_project}_exit_a_run" "${legacy_project}_exit_b_run" >/dev/null 2>&1 || true
    fi
    rm -rf "${workdir}" >/dev/null 2>&1 || true
}

on_sigint() {
    echo
    echo "[warn] interrupted, cleaning up..."
    cleanup
    exit 130
}

trap cleanup EXIT
trap on_sigint INT TERM HUP QUIT

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[error] missing command: $1" >&2
        exit 1
    }
}

print_message_about_nyx() {
    cat <<MSG
[!] If you want to monitor or manage the exit nodes (live status, circuits, bandwidth, and basic stats),
you can use Nyx — a terminal-based monitor and controller for Tor.

Open a second terminal tab/window and run one of these commands:
docker exec -it ${exit_a_container} sh -lc 'nyx --socket /run/tor/control.sock'
docker exec -it ${exit_b_container} sh -lc 'nyx --socket /run/tor/control.sock'


MSG
}

need docker
docker compose version >/dev/null 2>&1 || {
    echo "[error] docker compose is required" >&2
    exit 1
}

monero_version="${MONERO_VERSION:-v0.18.5.1}"
monero_commit="${MONERO_COMMIT:-4f92268d7c16741cfb41e5bbe2aa46cc260a9ea5}"
if [[ ! "${monero_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "[error] invalid Monero release tag: ${monero_version}" >&2
    exit 1
fi
if [[ ! "${monero_commit}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "[error] invalid Monero commit: ${monero_commit}" >&2
    exit 1
fi

gen_docker_networks 29
echo "[info] external network: ${ext_network_container_subnet_cidr_ipv4}"
echo "[info] internal network: ${int_network_container_subnet_cidr_ipv4}"
echo "[info] Monero release: ${monero_version}"
echo "[info] image mode: ${image_mode}"
echo "[info] image tag: ${image_tag}"
echo "[info] wallet vault: ${wallet_vault_host_path} (${wallet_vault_size})"

export project wallet_store_host_dir wallet_vault_name wallet_vault_host_path wallet_vault_size
export monero_version monero_commit
export exit_image haproxy_image monero_image
export exit_a_container exit_b_container haproxy_container monero_container
export ext_network_container_subnet_cidr_ipv4 ext_network_container_gateway_ipv4
export ext_network_container_exit_a_ipv4 ext_network_container_exit_b_ipv4
export int_network_container_subnet_cidr_ipv4 int_network_container_gateway_ipv4
export int_network_container_exit_a_ipv4 int_network_container_exit_b_ipv4
export int_network_container_haproxy_ipv4 int_network_container_app_ipv4

echo "[info] workdir: ${workdir}"
echo "[info] preclean old test stack"
cleanup_project
start_guard
install -d -m 700 "${wallet_store_host_dir}"
if [[ "${image_mode}" == "pull" ]]; then
    echo "[info] pulling published multi-architecture images"
    compose pull
else
    echo "[info] building Alpine images and source-built Monero image"
    if [[ "${NO_CACHE:-0}" == "1" ]]; then
        compose build --pull --no-cache
    else
        compose build --pull
    fi
fi

echo "[info] starting containers"
compose up -d --force-recreate --no-build

wipe_host
print_message_about_nyx
echo "[info] waiting for at least one exit node to become healthy (exit_a/exit_b)"
print_diagnostics() {
    set +e
    echo
    echo "[diagnostics] docker ps"
    docker ps -a --filter "name=mgla-" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" || true
    echo
    echo "[diagnostics] exit_a health"
    docker inspect -f "{{range .State.Health.Log}}{{printf \"[%s] code=%d %s\\n\" .Start .ExitCode .Output}}{{end}}" "${exit_a_container}" 2>/dev/null || true
    echo
    echo "[diagnostics] exit_b health"
    docker inspect -f "{{range .State.Health.Log}}{{printf \"[%s] code=%d %s\\n\" .Start .ExitCode .Output}}{{end}}" "${exit_b_container}" 2>/dev/null || true
    echo
    echo "[diagnostics] exit_a logs"
    docker logs "${exit_a_container}" --tail=120 2>/dev/null || true
    echo
    echo "[diagnostics] exit_b logs"
    docker logs "${exit_b_container}" --tail=120 2>/dev/null || true
    echo
    echo "[diagnostics] haproxy logs"
    docker logs "${haproxy_container}" --tail=120 2>/dev/null || true
    echo
    echo "[diagnostics] monero logs"
    docker logs "${monero_container}" --tail=120 2>/dev/null || true
}

winner=""
for ((i=1; i<=420; i++)); do
    a="$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" "${exit_a_container}" 2>/dev/null || true)"
    b="$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" "${exit_b_container}" 2>/dev/null || true)"
    if [[ "${a}" == "healthy" ]]; then winner="exit_a"; break; fi
    if [[ "${b}" == "healthy" ]]; then winner="exit_b"; break; fi
    if (( i % 30 == 0 )); then
        echo "[info] waiting... ${i}s exit_a=${a:-unknown} exit_b=${b:-unknown}"
    fi
    sleep 1
done

if [[ -z "${winner}" ]]; then
    echo "[error] neither Tor exit became healthy" >&2
    print_diagnostics >&2
    exit 1
fi

echo "[info] Exit node ready: ${winner}"
other="exit_a"
[[ "${winner}" == "exit_a" ]] && other="exit_b"
other_container="${exit_a_container}"
[[ "${other}" == "exit_b" ]] && other_container="${exit_b_container}"
other_state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${other_container}" 2>/dev/null || true)"
if [[ "${other_state}" != "healthy" ]]; then
    echo "[info] ${other} is not healthy yet (continuing)."
fi
echo "[info] waiting for HAProxy to mark backend up"
haproxy_ready=0
for ((j=1; j<=30; j++)); do
    if docker logs "${haproxy_container}" --tail=80 2>/dev/null | grep -Eq "Server socks_pool/exit_(a|b) is UP|socks_pool/exit_(a|b) changed its SSL|Health check for server socks_pool/exit_(a|b) succeeded"; then
        haproxy_ready=1
        break
    fi
    if (( j % 10 == 0 )); then
        echo "[info] waiting... ${j}s HAProxy backend=starting"
    fi
    sleep 1
done
if (( haproxy_ready == 1 )); then
    echo "[ok] HAProxy backend is ready"
else
    echo "[warn] HAProxy backend is not confirmed yet; network test will verify it"
fi

echo "[info] running Monero network test"
echo "[test] direct internet must be blocked from internal network"
direct_json="$(docker exec "${monero_container}" curl -fsS --max-time 8 https://check.torproject.org/api/ip 2>/dev/null || true)"
if [[ -n "${direct_json}" ]]; then
    echo "[error] direct curl unexpectedly succeeded"
    echo "${direct_json}"
    exit 1
fi
echo "[ok] direct curl blocked"
echo "[test] Tor through HAProxy SOCKS5h must work"
tor_json="$(docker exec "${monero_container}" curl -fsS --max-time 15 --proxy "socks5h://${int_network_container_haproxy_ipv4}:9095" https://check.torproject.org/api/ip 2>/dev/null || true)"
if [[ "${tor_json}" != *IsTor*true* ]]; then
    echo "[error] Tor SOCKS5h through HAProxy failed" >&2
    echo "${tor_json}" >&2
    exit 1
fi
echo "${tor_json}"
echo "[ok] Tor SOCKS5h via HAProxy works"

echo "[info] checking encrypted wallet vault"
docker exec -i "${monero_container}" /bin/sh <<'EOS'
set -eu
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir "${tmp}/source" "${tmp}/destination" "${tmp}/wrong"
printf '%s\n' 'vault smoke test' > "${tmp}/source/test.wallet"
printf '%s\n' 'test-password' | /opt/monero/mgla-vault \
    --password-fd 0 create "${tmp}/wallets.mgla" 1M "${tmp}/source"
printf '%s\n' 'test-password' | /opt/monero/mgla-vault \
    --password-fd 0 unpack "${tmp}/wallets.mgla" "${tmp}/destination"
cmp "${tmp}/source/test.wallet" "${tmp}/destination/test.wallet"
if printf '%s\n' 'wrong-password' | /opt/monero/mgla-vault \
    --password-fd 0 unpack "${tmp}/wallets.mgla" "${tmp}/wrong"; then
    echo '[error] vault accepted an invalid password' >&2
    exit 1
fi
EOS
echo "[ok] encrypted wallet vault passed smoke test"

echo "[info] checking verified Monero binary"
monero_version="$(docker exec "${monero_container}" /opt/monero/monero-wallet-cli --version 2>/dev/null || true)"
[[ -n "${monero_version}" ]] || {
    echo "[error] verified Monero binary is not runnable" >&2
    exit 1
}
echo "${monero_version}" | head -n 1

echo "[ok] Tor + HAProxy + Monero test passed"
if [[ "${CI:-0}" == "1" || "${SKIP_WALLET_MENU:-0}" == "1" ]]; then
    echo "[info] CI mode enabled; wallet menu skipped"
    exit 0
fi
echo "[info] starting Monero wallet menu (daemon discovery runs through Tor)"
docker_exec_flags=(-i)
if [ -t 0 ]; then
    docker_exec_flags=(-it)
fi
docker exec "${docker_exec_flags[@]}" "${monero_container}" /opt/app/monero
