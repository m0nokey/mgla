# Bitcoin CLI module

This module runs the official Electrum command-line wallet through a
disposable Tor transport. It is an Electrum client, not a Bitcoin Core daemon:
it connects to Electrum servers and never synchronizes a local Bitcoin Core
blockchain.

## Build

The final image is built from the signed official Electrum source archive in a
multi-stage Alpine 3.24 build. The builder verifies the ThomasV GPG signature
and the pinned SHA-256 digest, installs only the hash-locked runtime
dependencies, runs the offline version/import checks, and is discarded before
the final image is produced.

The runtime image contains Python and the libraries required by Electrum, but
not compilers, GPG, pip, GUI dependencies, or a Bitcoin daemon. The
requirements.lock file is included in the module build context and is
hash-pinned.

## Run

From the repository root:

~~~bash
bash ./run.sh
~~~

Select 2. Bitcoin wallet. For direct module invocation:

~~~bash
bash bitcoin/bitcoin-cli.sh
~~~

The default mode pulls:

~~~text
ghcr.io/m0nokey/mgla-exit:latest
ghcr.io/m0nokey/mgla-haproxy:latest
ghcr.io/m0nokey/mgla-bitcoin:latest
~~~

For a local source build:

~~~bash
IMAGE_MODE=build IMAGE_REGISTRY= IMAGE_TAG=local bash ./run.sh
~~~

The default host wallet directory is:

~~~text
$HOME/.mgla/bitcoin/
~~~

Override it with an absolute path:

~~~bash
BITCOIN_WALLET_STORE_HOST_DIR=/absolute/path/to/bitcoin bash bitcoin/bitcoin-cli.sh
~~~

Wallet files are bind-mounted only into the non-root Bitcoin container. No
wallet directory is published by Docker and no network service is exposed to
the host.

## Network model

The application is at the bottom and has no direct Internet route:

~~~text
                         Electrum server (.onion)
                                      ▲
                                      │ Tor network
                         ┌────────────┴────────────┐
                         │                         │
                     exit-a                      exit-b
                         ▲                         ▲
                         └────────────┬────────────┘
                                      │
                       haproxy (SOCKS relay)
                                      ▲
                                      │ internal_network only
                                      │
                                bitcoin-cli
~~~

The Bitcoin container is attached only to Docker's internal_network. It has no
published ports and cannot bypass HAProxy. HAProxy has no external network
attachment; its backend contains only the two Tor exits. The exits are the only
services attached to the external bridge.

Electrum is configured with socks5:HOST:9095; its SOCKS connector performs
remote DNS resolution through the proxy. The launcher disables automatic
server selection and probes only the pinned official .onion candidates from
Electrum's mainnet server list. It selects the reachable candidate with the
highest reported chain height, then keeps that server for the session. A
server-reported height is a routing signal, not independent proof that a
remote server is honest.

## Wallet menu

The launcher provides:

- network status and selected server details;
- create a new wallet;
- restore a wallet from a seed;
- open an existing wallet;
- receive addresses and QR codes;
- balance and synchronization status;
- fee estimates and explicit transaction review/sign/broadcast steps;
- diagnostics and manual onion-server selection.

Transaction input is deliberately strict. The launcher bounds every line,
rejects control characters, accepts only mainnet address syntax, asks Electrum
to verify the address checksum and network, parses BTC amounts as integer
satoshis without floating-point arithmetic, and validates fee rates as exact
milli-satoshi-per-vbyte values. It creates an unsigned preview and requires an
exact `YES` confirmation before signing and broadcasting. Wallet passwords and
seed phrases are entered directly into Electrum and are never captured by the
launcher.

The wallet password is entered directly into Electrum and is not stored by the
launcher. The outer host script starts the application with a direct command:

~~~bash
docker exec -it mgla-bitcoin /opt/app/bitcoin
~~~

There is no sh -lc wrapper around the wallet command.

## Security and CI

The module shares the hardened Alpine Tor and HAProxy images with Monero.
The Bitcoin workflow performs:

- actionlint and ShellCheck;
- Compose interpolation validation;
- Trivy Dockerfile/Compose misconfiguration scanning;
- native amd64 and arm64 source builds;
- direct-route blocking and Tor SOCKS5h integration tests;
- signed Electrum version and runtime import checks;
- official onion-server discovery checks;
- Trivy OS and library scans for exit, haproxy, and bitcoin;
- SARIF upload to GitHub Code Scanning;
- scheduled rescans of the published latest manifests.

Pull requests and non-main pushes validate only. The separate publish job on
main pushes one multi-architecture latest manifest set to GHCR and removes
obsolete package versions after retaining the manifests referenced by latest.

See the Bitcoin workflow:
https://github.com/m0nokey/mgla/actions/workflows/bitcoin.yml
