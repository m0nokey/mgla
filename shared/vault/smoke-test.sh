#!/usr/bin/env bash
set -Eeuo pipefail

vault_binary="${1:?vault binary path is required}"
[[ -x "${vault_binary}" ]]

tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp}"' EXIT

mkdir "${tmp}/source" "${tmp}/destination" "${tmp}/wrong"
printf '%s\n' 'vault smoke test' > "${tmp}/source/test.wallet"

printf '%s\n' 'test-password' | "${vault_binary}" \
    --password-fd 0 create "${tmp}/wallets.mgla" 1M "${tmp}/source"
printf '%s\n' 'test-password' | "${vault_binary}" \
    --password-fd 0 unpack "${tmp}/wallets.mgla" "${tmp}/destination"
cmp "${tmp}/source/test.wallet" "${tmp}/destination/test.wallet"

if printf '%s\n' 'wrong-password' | "${vault_binary}" \
    --password-fd 0 unpack "${tmp}/wallets.mgla" "${tmp}/wrong"; then
    printf '%s\n' '[error] vault accepted an invalid password' >&2
    exit 1
fi
