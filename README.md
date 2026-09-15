# mgla

`mgla` is a privacy-oriented Docker workspace for cryptocurrency CLI wallets.
The project provides separate Monero and Bitcoin modules with disposable Tor
transport, strict container isolation, and continuously tested dependencies.

## Quick start

Requirements: Docker Engine or Docker Desktop with Compose v2, and Bash.

Clone the repository and start the project menu:

```bash
git clone https://github.com/m0nokey/mgla.git \
&& cd mgla \
&& bash ./run.sh
```

Without Git:

```bash
install -d -m 0700 mgla \
&& curl -fsSL --proto '=https' 'https://github.com/m0nokey/mgla/archive/refs/heads/main.tar.gz' | tar -xz --strip-components=1 -C mgla \
&& cd mgla \
&& bash ./run.sh
```

`run.sh` is the normal entry point and opens the module menu:

```text
mgla
------------------------------------------------------------
1. Monero wallet
2. Bitcoin wallet
q. Exit
------------------------------------------------------------
```

The default mode pulls the latest published multi-architecture images from
GHCR. To build the selected module locally instead:

```bash
IMAGE_MODE=build IMAGE_REGISTRY= IMAGE_TAG=local bash ./run.sh
```

The `main` branch publishes these images only after build, integration tests,
and security scans succeed:

```text
ghcr.io/m0nokey/mgla-exit:latest
ghcr.io/m0nokey/mgla-haproxy:latest
ghcr.io/m0nokey/mgla-monero:latest
ghcr.io/m0nokey/mgla-bitcoin:latest
```

## Modules

- `monero/` — Monero CLI wallet with fresh onion-daemon discovery and fixed-size encrypted `.mgla` vaults.
- `bitcoin/` — Electrum CLI wallet with signed source verification and official onion-server discovery.

Both modules use the same hardened Alpine Tor and HAProxy images. The module
scripts are lifecycle controllers used by `run.sh`, CI, and direct development
checks; `run.sh` remains the normal user entry point.

## Network model

The route is shown from the wallet upward. The wallet container is at the
bottom and has no direct Internet route:

```text
                         Monero daemon / Electrum server (.onion)
                                           ▲
                                           │ Tor network
                         ┌─────────────────┴─────────────────┐
                         │                                   │
                       exit-a                              exit-b
                         ▲                                   ▲
                         └─────────────────┬─────────────────┘
                                           │
                              haproxy (SOCKS5 relay)
                                           ▲
                                           │ internal_network only
                                           │
                              monero-cli / bitcoin-cli
```

`monero-cli` and `bitcoin-cli` are attached only to Docker's `internal_network`.
They expose no host ports and cannot bypass HAProxy. HAProxy is attached only
to the internal network and reaches the Internet through the two independent
Tor exits. The exits are the only services attached to the external bridge.

Monero uses SOCKS5h for daemon discovery and RPC requests. Electrum uses a
remote-DNS SOCKS5 connector for its `.onion` server connections. Docker
subnets and service addresses are generated for each run by the launcher; no
runtime network address is embedded in a published image.

## Wallet data

Monero vaults are stored on the host in `$HOME/.mgla/` by default:

```text
$HOME/.mgla/
├── personal.mgla
└── savings.mgla
```

A new vault is a fixed-size 128 MiB encrypted file and can contain multiple
named Monero wallets. The vault is decrypted only into the Monero container's
private tmpfs and is cleared when the session ends. The vault password is
shown once when a vault is created; losing it means losing access to that
vault. A Monero seed can recover the wallet, but not local labels or cache.

Bitcoin Electrum wallet files are stored in `$HOME/.mgla/bitcoin/` by default
and are bind-mounted only into the selected non-root Bitcoin container. Override
the directory with `BITCOIN_WALLET_STORE_HOST_DIR=/absolute/path` when using
the Bitcoin module.

## Security and CI

The project's security objective is to make container and dependency security
continuously testable and to reduce supply-chain and remote-code-execution
(RCE) exposure. No scanner can prove that software has zero possible CVEs or
RCEs, so findings remain visible even when they are not release blockers.

The CI pipeline performs:

- native `linux/amd64` and `linux/arm64` builds;
- signed and hash-pinned upstream wallet verification;
- direct-route blocking and Tor integration tests;
- actionlint, ShellCheck, Compose, and Python validation;
- Trivy Dockerfile/Compose misconfiguration scans;
- Trivy OS and library scans for every final image;
- SARIF upload to GitHub Code Scanning.

Validation jobs use read-only permissions. Only the separate publish job on
`main` receives registry write permission. Pull requests and non-`main`
pushes validate without publishing images. Scheduled rescans check the
published `latest` images for newly disclosed vulnerabilities.

Open the relevant workflow and select the newest completed run:

- [Monero workflow](https://github.com/m0nokey/mgla/actions/workflows/monero.yml)
- [Bitcoin workflow](https://github.com/m0nokey/mgla/actions/workflows/bitcoin.yml)

The run **Summary** contains the per-image vulnerability table. Full SARIF
results are available under **Security → Code scanning**, and each matrix
job uploads an architecture-specific report artifact.

## Project layout

```text
.
├── README.md
├── run.sh
├── monero/
│   ├── monero-cli.sh
│   ├── compose.yaml
│   ├── ci/security-summary.py
│   └── docker/
│       ├── exit/
│       ├── haproxy/
│       └── monero/
└── bitcoin/
    ├── bitcoin-cli.sh
    ├── compose.yaml
    ├── ci/security-summary.py
    ├── requirements.lock
    └── docker/bitcoin/
```

See the module documentation for implementation details:

- [Monero module](monero/README.md)
- [Bitcoin module](bitcoin/README.md)
