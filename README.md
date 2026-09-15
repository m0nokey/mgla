# mgla

`mgla` is a privacy-oriented container workspace for cryptocurrency CLI
wallets. Each module uses two independent Tor exits and an internal HAProxy
SOCKS relay; the wallet container has no direct Internet route.

## Available modules

- `monero/` — Monero CLI wallet with disposable onion-daemon discovery and
  encrypted `.mgla` wallet vaults.
- `bitcoin/` — Bitcoin wallet through the official Electrum CLI, using only
  official `.onion` Electrum servers.

## Quick Start

Requirements:

- Docker Engine or Docker Desktop;
- Docker Compose v2;
- Bash.

With Git:

```bash
git clone https://github.com/m0nokey/mgla.git \
&& cd mgla \
&& bash ./run.sh
```

Without Git:

```bash
install -d -m 0700 mgla \
&& curl -fsSL https://github.com/m0nokey/mgla/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1 -C mgla \
&& cd mgla \
&& bash ./run.sh
```

`run.sh` opens the project menu:

```text
mgla
------------------------------------------------------------
1. Monero wallet
2. Bitcoin wallet
q. Exit
------------------------------------------------------------
```

By default, a scenario pulls the latest multi-architecture images from GHCR.
To build the selected module and its shared Tor/HAProxy images locally:

```bash
IMAGE_MODE=build IMAGE_REGISTRY= IMAGE_TAG=local bash ./run.sh
```

The published images are:

```text
ghcr.io/m0nokey/mgla-exit:latest
ghcr.io/m0nokey/mgla-haproxy:latest
ghcr.io/m0nokey/mgla-monero:latest
ghcr.io/m0nokey/mgla-bitcoin:latest
```

## Network model

Every module keeps the wallet at the bottom of the route:

```text
                         wallet daemon or server (.onion)
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
                           monero-cli / bitcoin-cli
```

The wallet container is attached only to Docker's `internal_network` and has
no published ports or direct Internet route. HAProxy is attached only to the
internal network and can reach the Internet only through the two Tor exits.
The exits are the only services attached to the external bridge.

Docker subnets and container addresses are generated at runtime. They are
passed to Compose and are not embedded in published images.

## Wallet storage

Monero vaults are stored in `$HOME/.mgla/`. New vaults are fixed-size encrypted
files that can contain multiple named Monero wallets. Bitcoin Electrum wallet
files are stored in `$HOME/.mgla/bitcoin/` by default.

The host bind mounts contain wallet data for the selected module only. Bitcoin
wallet files remain inside the application container's private internal
network and are never exposed through a published service port. See each
module README for its storage and recovery details.

## Security objective

The project is designed to make container and dependency security continuously
testable and to reduce supply-chain and remote-code-execution (RCE) exposure:

- minimal Alpine 3.24 runtime images;
- non-root, read-only containers with dropped capabilities;
- two Tor exits with HAProxy health checks and failover;
- no direct Internet route from either wallet container;
- signed and hash-pinned upstream wallet sources;
- native `linux/amd64` and `linux/arm64` builds;
- Trivy OS/library vulnerability scans and Docker misconfiguration scans;
- SARIF reports uploaded to GitHub Code Scanning.

Validation jobs use read-only permissions. Only the separate `publish` job on
`main` receives `packages: write`. A successful build is required before
multi-architecture `latest` manifests are published. The scheduled workflow
rescans published images for newly disclosed high and critical findings.

The [Monero workflow](https://github.com/m0nokey/mgla/actions/workflows/monero.yml)
and [Bitcoin workflow](https://github.com/m0nokey/mgla/actions/workflows/bitcoin.yml)
open the latest run at the top. Select **Summary** to view the compact
per-image vulnerability table. Full SARIF results are available under
**Security → Code scanning alerts**, and each architecture also has a
downloadable report artifact.

## Project layout

```text
run.sh
monero/
├── monero-cli.sh
├── compose.yaml
├── ci/security-summary.py
└── docker/
    ├── exit/
    ├── haproxy/
    └── monero/
bitcoin/
├── bitcoin-cli.sh
├── compose.yaml
├── ci/security-summary.py
├── requirements.lock
└── docker/bitcoin/
```

See [monero/README.md](monero/README.md) and
[bitcoin/README.md](bitcoin/README.md) for module-specific instructions.
