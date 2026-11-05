#!/bin/sh
set -eu

applets="$(busybox --list)"
for path in /bin/* /sbin/* /usr/bin/* /usr/sbin/*; do
    [ -L "${path}" ] || continue
    [ "$(readlink -f "${path}")" = /bin/busybox ] || continue
    if ! printf '%s\n' "${applets}" | grep -Fxq "${path##*/}"; then
        rm -f -- "${path}"
    fi
done
