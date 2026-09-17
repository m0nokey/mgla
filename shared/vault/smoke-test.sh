#!/bin/sh
set -eu

vault_binary="${1:?vault binary path is required}"
if [ ! -x "${vault_binary}" ]; then
    printf '%s\n' '[error] vault binary is missing or not executable' >&2
    exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp}"' 0

mkdir "${tmp}/source" "${tmp}/destination" "${tmp}/wrong"
printf '%s\n' 'vault smoke test' > "${tmp}/source/test.wallet"

printf '%s\n' 'test-password' | "${vault_binary}" \
    --password-fd 0 create "${tmp}/wallets.mgla" 1M "${tmp}/source"
if printf '%s\n' 'wrong-password' | "${vault_binary}" \
    --password-fd 0 pack "${tmp}/wallets.mgla" "${tmp}/source"; then
    printf '%s\n' '[error] vault accepted an invalid password for pack' >&2
    exit 1
fi
printf '%s\n' 'test-password' | "${vault_binary}" \
    --password-fd 0 unpack "${tmp}/wallets.mgla" "${tmp}/destination"
cmp "${tmp}/source/test.wallet" "${tmp}/destination/test.wallet"

if printf '%s\n' 'wrong-password' | "${vault_binary}" \
    --password-fd 0 unpack "${tmp}/wallets.mgla" "${tmp}/wrong"; then
    printf '%s\n' '[error] vault accepted an invalid password' >&2
    exit 1
fi
