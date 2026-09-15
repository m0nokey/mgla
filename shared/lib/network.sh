#!/usr/bin/env bash

# Generate short-lived Docker network ranges without embedding addresses in an
# image. The caller must export the resulting variables before invoking
# docker compose.

rand_u8() {
    local minimum="${1:-0}"
    local maximum="${2:-255}"
    local range=$((maximum - minimum + 1))
    local random_value=$(( (RANDOM << 15) ^ RANDOM ))

    printf '%d' $((random_value % range + minimum))
}

docker_subnets() {
    local network_id
    local -a network_ids=()

    while IFS= read -r network_id; do
        if [[ -n "${network_id}" ]]; then
            network_ids+=("${network_id}")
        fi
    done < <(docker network ls -q 2>/dev/null || true)

    if ((${#network_ids[@]} == 0)); then
        return 0
    fi

    docker network inspect "${network_ids[@]}" \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || true
}

cidr_overlaps() {
    local first="${1}"
    local second="${2}"

    awk -v first="${first}" -v second="${second}" '
        function ip_to_int(ip, octets) {
            split(ip, octets, ".")
            return octets[1] * 16777216 + octets[2] * 65536 + octets[3] * 256 + octets[4]
        }
        function cidr_start(cidr, fields, ip, prefix, block, value) {
            split(cidr, fields, "/")
            ip = fields[1]
            prefix = fields[2] + 0
            block = 2 ^ (32 - prefix)
            value = ip_to_int(ip)
            return int(value / block) * block
        }
        function cidr_end(cidr, fields, prefix, block) {
            split(cidr, fields, "/")
            prefix = fields[2] + 0
            block = 2 ^ (32 - prefix)
            return cidr_start(cidr) + block - 1
        }
        BEGIN {
            first_start = cidr_start(first)
            first_end = cidr_end(first)
            second_start = cidr_start(second)
            second_end = cidr_end(second)
            exit((first_end < second_start || first_start > second_end) ? 1 : 0)
        }
    '
}

subnet_free() {
    local candidate="${1}"
    local subnet

    while IFS= read -r subnet; do
        if [[ -n "${subnet}" ]] && cidr_overlaps "${candidate}" "${subnet}"; then
            return 1
        fi
    done < <(docker_subnets)

    return 0
}

generate_networks() {
    local mask=29
    local ext_second ext_third int_second int_third
    local found attempt

    found=0
    for ((attempt = 1; attempt <= 512; attempt++)); do
        ext_second="$(rand_u8 19 119)"
        ext_third="$(rand_u8 0 255)"
        ext_network_container_subnet_cidr_ipv4="10.${ext_second}.${ext_third}.0/${mask}"
        if subnet_free "${ext_network_container_subnet_cidr_ipv4}"; then
            found=1
            break
        fi
    done
    if ((found != 1)); then
        printf '%s\n' '[error] could not find a free Docker external subnet' >&2
        return 1
    fi

    ext_network_container_gateway_ipv4="10.${ext_second}.${ext_third}.1"
    ext_network_container_exit_a_ipv4="10.${ext_second}.${ext_third}.2"
    ext_network_container_exit_b_ipv4="10.${ext_second}.${ext_third}.3"

    found=0
    for ((attempt = 1; attempt <= 512; attempt++)); do
        int_second="$(rand_u8 121 221)"
        int_third="$(rand_u8 0 255)"
        int_network_container_subnet_cidr_ipv4="10.${int_second}.${int_third}.0/${mask}"
        if subnet_free "${int_network_container_subnet_cidr_ipv4}"; then
            found=1
            break
        fi
    done
    if ((found != 1)); then
        printf '%s\n' '[error] could not find a free Docker internal subnet' >&2
        return 1
    fi

    int_network_container_gateway_ipv4="10.${int_second}.${int_third}.1"
    int_network_container_exit_a_ipv4="10.${int_second}.${int_third}.2"
    int_network_container_exit_b_ipv4="10.${int_second}.${int_third}.3"
    int_network_container_haproxy_ipv4="10.${int_second}.${int_third}.4"
    int_network_container_app_ipv4="10.${int_second}.${int_third}.5"
}
