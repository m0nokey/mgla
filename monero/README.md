# Monero module

This module runs the Monero command-line wallet through the shared disposable
Tor transport. It uses the root Compose file's `monero` profile and keeps the
interactive wallet and vault logic in this directory.

## Layout

- `Dockerfile` — multi-stage Alpine 3.24 source build of `monero-wallet-cli`.
- `monero-cli.sh` — lifecycle controller used by `run.sh` and CI.
- `wallet-launcher.sh` — wallet menu and vault session UI copied into the image.
- `../network/exit` — shared hardened Tor exit image.
- `../network/haproxy` — shared internal SOCKS relay image.
- `../shared/lib/network.sh` — shared random Docker subnet generation.
- `../shared/vault` — shared Rust encrypted-file utility used at build time.

There is no helper container and no test-client service. Network checks run from
the final `mgla-monero` container itself.

## Run locally

From the repository root:

```bash
bash ./run.sh
```

Select `1. Monero wallet`. For direct module invocation:

```bash
bash monero/monero-cli.sh
```

The default mode pulls:

```text
ghcr.io/m0nokey/mgla-exit:latest
ghcr.io/m0nokey/mgla-haproxy:latest
ghcr.io/m0nokey/mgla-monero:latest
```

For a local source build:

```bash
IMAGE_MODE=build IMAGE_REGISTRY= IMAGE_TAG=local bash ./run.sh
```

The host stores shared encrypted vault files in `$HOME/.mgla/` by default.
A single `.mgla` file can contain Monero data under `monero/` and Bitcoin data
under `bitcoin/`. The complete decrypted vault exists only in the container's
private tmpfs; the launcher uses the Monero subdirectory and removes the
plaintext tree on exit.

## Network model

The wallet is at the bottom and has no direct Internet route:

```text
                         Monero daemon (.onion)
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
                                monero-cli
```

`mgla-monero` is attached only to `internal_network`. It has no published
ports and cannot bypass HAProxy. HAProxy reaches only the two Tor exits, and
the exits are the only services attached to the external bridge.

Daemon discovery and Monero RPC requests use `SOCKS5h`, so hostname resolution
is performed through Tor. A remote daemon remains untrusted unless explicitly
marked trusted by the wallet; the transport does not remove that trust choice.

## Wallet and vault

The wallet menu can create, restore, open, and close named wallet directories
inside the selected vault. A daemon is selected afresh for each wallet session
from reachable onion nodes, preferring the highest reported chain height.

The Rust vault is a shared userspace utility. It uses authenticated encryption
building blocks, fixed-size images, a per-vault random salt, and zeroization of
sensitive buffers. It never mounts a block device and the plaintext wallet tree
exists only in the container's private tmpfs during the session. The vault
password is displayed once when a vault is created; losing it means losing
access to that vault. A seed can recover a Monero wallet, but not local labels
or cache.

## Security checks

CI builds both supported architectures and verifies:

- the pinned Monero source revision and Alpine runtime links;
- the shared Rust vault tests, formatting, Clippy, and advisory audit;
- direct-route blocking and Tor SOCKS5h connectivity;
- OSV and CodeQL dependency/source checks;
- Trivy and Grype OS and library findings for exit, HAProxy, and Monero images.

The release policy blocks fixable `MEDIUM`, `HIGH`, and `CRITICAL` findings. See
the [latest CI workflow](https://github.com/m0nokey/mgla/actions/workflows/ci.yml)
for the Summary table and SARIF reports.
