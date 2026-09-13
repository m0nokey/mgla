# Monero module

This module runs the Monero CLI wallet through a disposable Tor transport.
The wallet menu, daemon discovery, named wallet directories, and Nyx hints are
kept in the launcher so the normal interactive workflow remains unchanged.

## Layout

- `monero-cli.sh` — the real launcher and lifecycle controller.
- `compose.yaml` — the four-service stack definition.
- `docker/exit` — one hardened Alpine image used by `mgla-exit-a` and `mgla-exit-b`.
- `docker/haproxy` — the internal SOCKS5/SOCKS5h broker image.
- `docker/monero` — a multi-stage Alpine source build and the wallet menu.

There is no helper container and no test-client service. Network checks run from
the final `mgla-monero` container itself.

## Run locally

From the repository root:

```bash
bash monero-cli.sh
```

The compatibility wrapper at the repository root (`monero-cli.sh`) delegates to this module, so
running `bash monero-cli.sh` from the repository root also works.

Wallet files are mounted from the host. The default is:

```text
$HOME/Downloads/Monero/wallets
```

Set an explicit absolute path when needed:

```bash
WALLET_HOST_DIR=/absolute/path/to/monero/wallets bash monero-cli.sh
```

The menu lets you open an existing wallet, create a new named wallet, restore a
wallet from its seed, return to the wallet list, or exit. A daemon is selected
afresh for each wallet session from currently reachable onion nodes, preferring
the highest reported height.

## Network model

The wallet route is shown from the application upward. The application cannot
bypass the internal SOCKS broker:

```text
                         Monero onion daemon (.onion)
                                      ▲
                                      │ Tor network
                         ┌────────────┴────────────┐
                         │                         │
                  mgla-exit-a                 mgla-exit-b
                         ▲                         ▲
                         └────────────┬────────────┘
                                      │
                    mgla-haproxy (SOCKS5/SOCKS5h)
                                      ▲
                                      │ internal_network only
                                      │
                                mgla-monero
```

`mgla-monero` is attached only to Docker's `internal_network`. It has no direct
Internet route and no published host ports. `mgla-haproxy` is the only egress
broker visible to the application. Both exit containers have separate Tor
state volumes, and HAProxy health checks fail over between them.

The launcher performs daemon discovery and every `/get_info` request through
`SOCKS5h`, so hostname resolution is performed by Tor. This protects the
application's direct network path; it does not make a remote daemon trusted or
provide a blanket anonymity guarantee.

## Security objective

The primary purpose of this project is to make library and container security
continuously testable and to reduce supply-chain and remote-code-execution
(RCE) exposure:

- keep final images minimal and run services as non-root users;
- pin Alpine security fixes and the Monero source revision;
- build only the Monero CLI wallet and verify its architecture and runtime linkage;
- prevent the wallet from reaching the Internet outside the Tor path;
- build both supported architectures and scan every final image in CI.

The initial CI policy treats known fixable `critical` and `high` findings as
release blockers. No scanner can prove that an image contains zero possible
CVEs or RCEs, so unfixed and newly disclosed issues still require review and
an explicit dependency update.

## Build and verification

The Monero wallet is built from the pinned `v0.18.5.1` source commit in an
Alpine builder, following the dependency model maintained by Alpine's official
`community/monero` APKBUILD. Only CMake's `simplewallet` target is requested;
the daemon, RPC server, GUI, tests, and debug utilities are not built. The
binary architecture and all runtime links are checked before the disposable
builder stage is discarded. Trezor support is intentionally disabled in this
minimal first version and can be added as a separate module option.

GitHub Actions builds `linux/amd64` and `linux/arm64` on native runners, runs
the Tor and network integration checks, and scans all three final images for
fixed critical and high vulnerabilities. The workflow validates only; it does
not publish images or require registry credentials.

Ordinary runs use Docker's layer cache and refresh the Alpine base manifest with
`--pull`. Use `NO_CACHE=1` only when deliberately forcing a clean local rebuild.
