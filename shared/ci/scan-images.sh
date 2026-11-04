#!/usr/bin/env bash
set -euo pipefail

grype="$1"
architecture="$2"
image_tag="$3"
shift 3

mkdir -p grype-verified grype-audit
status=0
for image in "$@"; do
    reference="${IMAGE_REGISTRY}/mgla-${image}:${image_tag}"
    image_id="$(docker image inspect --format '{{.Id}}' "${reference}")"
    scan_tag="mgla-vex.local/m0nokey/mgla-${image}:${image_id#sha256:}"
    docker image tag "${image_id}" "${scan_tag}"
    target="docker:${scan_tag}"
    report="grype-${image}-${architecture}"
    raw="grype-audit/${report}.json"
    vex="grype-audit/${report}.openvex.json"
    rm -f "${vex}"

    "${grype}" "${target}" -o json > "${raw}"
    python3 shared/ci/image-vex.py "${image}" "${image_id}" "${scan_tag}" "${raw}" "${vex}"

    options=()
    if [[ -s "${vex}" ]]; then
        options+=(--vex "${vex}")
    fi
    "${grype}" "${target}" "${options[@]}" -o sarif > "grype-verified/${report}.sarif"
    "${grype}" "${target}" "${options[@]}" --only-fixed --fail-on medium || status=1
done

exit "${status}"
