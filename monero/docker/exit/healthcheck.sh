#!/bin/sh
set -eu

[ -S /run/tor/control.sock ] || exit 1
[ -r /run/tor/control.authcookie ] || exit 1

cookie="$(xxd -p /run/tor/control.authcookie | tr -d '\n')"
tor-control /run/tor/control.sock "AUTHENTICATE $cookie" \
    "getinfo status/bootstrap-phase" |
    grep -q 'PROGRESS=100' || exit 1

tor-control /run/tor/control.sock "AUTHENTICATE $cookie" \
    "getinfo circuit-status" |
    grep -q 'BUILT' || exit 1
