# Bitcoin CLI module

This module runs the official Electrum command-line wallet through the shared
disposable Tor transport. It is an Electrum client, not a Bitcoin Core daemon:
it connects to Electrum servers and does not synchronize a local Bitcoin Core
blockchain.

## Layout

- `Dockerfile` — signed, hash-pinned Electrum build on Alpine 3.24.
- `bitcoin-cli.sh` — lifecycle controller used by `run.sh` and CI.
- `wallet-launcher.sh` — strict wallet UI and transaction validation.
- `entrypoint.sh` — direct container entrypoint.
- `network-check.py` — runtime connectivity check used by integration tests.
- `../network/exit` and `../network/haproxy` — shared Tor transport images.
- `../shared/lib/network.sh` — shared random Docker subnet generation.

## Run locally

From the repository root:

```bash
bash ./run.sh
```

Select `2. Bitcoin wallet`. For direct module invocation:

```bash
bash bitcoin/bitcoin-cli.sh
```

The default mode pulls:

```text
ghcr.io/m0nokey/mgla-exit:latest
ghcr.io/m0nokey/mgla-haproxy:latest
ghcr.io/m0nokey/mgla-bitcoin:latest
```

For a local source build:

```bash
IMAGE_MODE=build IMAGE_REGISTRY= IMAGE_TAG=local bash ./run.sh
```

The selected `.mgla` file is a shared encrypted vault. It can contain Bitcoin
data under `bitcoin/` and Monero data under `monero/`. The complete decrypted
vault exists only in the container tmpfs; the launcher uses the Bitcoin
subdirectory and removes the plaintext tree on exit. Override the host vault
directory with:

```bash
BITCOIN_WALLET_STORE_HOST_DIR=/absolute/path/to/vaults bash bitcoin/bitcoin-cli.sh
```

## Network model

The wallet is at the bottom and has no direct Internet route:

```text
                         Electrum server (.onion)
                                      ▲
                                      │ Tor network
                         ┌────────────┴────────────┐
                         │                         │
                     exit-a                      exit-b
                         ▲                         ▲
                         └────────────┬────────────┘
                                      │ external_network
                       haproxy (SOCKS5/SOCKS5h relay)
                                      ▲
                                      │ internal_network only
                                      │
                                bitcoin-cli
```

The Bitcoin container is attached only to `internal_network`; it has no
published ports and cannot bypass HAProxy. HAProxy is attached only to the
internal network, and the exits are the only services attached to the external
bridge. Electrum's SOCKS connector performs remote DNS resolution for onion
servers through the proxy.

At startup, the launcher fetches the current official Electrum [server list](https://raw.githubusercontent.com/spesmilo/electrum/refs/heads/master/electrum/chains/mainnet/servers.json) through the Tor proxy, extracts TLS (`s`) Onion entries, and probes them in source order. It selects the first working server. If no TLS Onion server responds, it tries Blockstream's official Onion Electrum endpoint `explorerzydxu5ecjrkwceayqybizmpjjznk5izmitf2modhcusuqlid.onion:110:t`. The matching `http://...onion/` address is the web Explorer on a different port, not the wallet protocol. If that Onion endpoint is unavailable, it tries `electrum.blockstream.info:50002:s` through the same Tor proxy.
A reported height is displayed for diagnostics, not treated as proof that a
remote server is honest.

## Security checks

CI verifies the signed Electrum archive, locked Python dependencies, the
encrypted wallet-vault binary, strict wallet input validation, direct-route
blocking, Tor connectivity, OSV and CodeQL checks, and Trivy and Grype
OS/library scans for all final images. The release gate blocks fixable
`MEDIUM`, `HIGH`, and `CRITICAL` findings. The final image does not contain
build compilers, GPG, pip, or a Bitcoin daemon.

The shared root workflow builds native amd64 and arm64 images and publishes
only after the integration and security gates pass. See the [latest CI
workflow](https://github.com/m0nokey/mgla/actions/workflows/ci.yml) for the
Summary table and SARIF reports.
