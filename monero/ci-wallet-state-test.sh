#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ "$(id -u)" != 0 ]] || { echo '[error] wallet test must run without root' >&2; exit 1; }
tmp="$(mktemp -d /monero/wallets/ci-state.XXXXXX)"
trap 'rm -rf -- "${tmp}"' EXIT
mkdir "${tmp}/source" "${tmp}/restored"
wallet=/opt/monero/monero-wallet-cli
vault=/opt/monero/mgla-vault
# Disposable, zero-balance CI wallets only. Never print their seed or keys.
password=ci-disposable-wallet-password
vault_password=ci-disposable-vault-password

timeout 90 "${wallet}" --offline \
    --generate-new-wallet "${tmp}/source/test" \
    --password "${password}" --mnemonic-language English \
    --restore-height 0 --subaddress-lookahead 1:1 --create-address-file \
    --log-file "${tmp}/create.log" --command address \
    </dev/null >"${tmp}/create-output" 2>&1
test -s "${tmp}/source/test.keys"
test -s "${tmp}/source/test"
test -s "${tmp}/source/test.address.txt"
address="$(cat "${tmp}/source/test.address.txt")"

printf '%s\n' "${vault_password}" | "${vault}" --password-fd 0 \
    create "${tmp}/wallet.mgla" 4M "${tmp}/source"
rm -rf -- "${tmp}/source"
printf '%s\n' "${vault_password}" | "${vault}" --password-fd 0 \
    unpack "${tmp}/wallet.mgla" "${tmp}/restored"
timeout 90 "${wallet}" --offline --wallet-file "${tmp}/restored/test" \
    --password "${password}" --log-file "${tmp}/reopen.log" --command address \
    </dev/null >"${tmp}/reopen-output" 2>&1
grep -Fq -- "${address}" "${tmp}/reopen-output"
printf '%s\n' '[ok] Monero software wallet create, save to vault, and reopen test passed'
