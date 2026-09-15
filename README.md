# mgla

`mgla` is a privacy-oriented container workspace for cryptocurrency CLI
wallets. Wallet modules use an isolated Tor transport instead of receiving a
direct Internet route.

Available now:

- `monero/` — Monero CLI wallet with two Tor exits and HAProxy failover.

Planned:

- `bitcoin/` — Bitcoin CLI wallet using the same transport model.

## Quick Start

Requirements:

- Docker Engine or Docker Desktop;
- Docker Compose v2;
- Bash.

Stable release archives are not published yet. Use the current `main` branch.

With Git:

```bash
git clone https://github.com/m0nokey/mgla.git
cd mgla
bash run.sh
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
q. Exit
------------------------------------------------------------
```

Select `1` to start the Monero scenario. By default it pulls the latest
multi-architecture images from GHCR. If the packages are private, authenticate
first with `docker login ghcr.io`.

To build all images locally instead:

```bash
IMAGE_MODE=build IMAGE_REGISTRY= IMAGE_TAG=local bash run.sh
```

## Network Model

The wallet is at the bottom and has no direct Internet route:

```text
                         Monero onion daemon (.onion)
                                      ▲
                                      │ Tor network
                         ┌────────────┴────────────┐
                         │                         │
                     exit-a                      exit-b
                         ▲                         ▲
                         └────────────┬────────────┘
                                      │
                       haproxy (Tor SOCKS relay)
                                      ▲
                                      │ internal_network only
                                      │
                                monero-cli
```

`mgla-monero` is attached only to Docker's internal network and has no direct
Internet route. `mgla-haproxy` also has no external network attachment; its
backend pool contains only the two Tor exit containers. The exit containers are
the only services attached to the external bridge.

Docker subnets and container addresses are generated at every launch and passed
to Compose at runtime. They are not embedded in the published images.

## Wallet Storage

Monero stores one fixed-size encrypted vault on the host. Its default capacity
is 128 MB. The default file is:

```text
$HOME/Downloads/Monero/wallets.mgla
```

Choose another host directory or vault filename when needed:

```bash
WALLET_STORE_HOST_DIR=/absolute/path/to/Monero \
WALLET_VAULT_NAME=portfolio.mgla bash run.sh
```

On first launch, the application generates a high-entropy vault password and
shows it once. Save it offline: losing it means losing access to the vault.
Wallet seed phrases can restore wallets, but they do not restore local wallet
cache and labels. The host receives only the encrypted vault file; wallets are
opened inside the Monero container in a private tmpfs and removed when the
launcher exits.

## Security Model

The project uses:

- non-root, read-only containers with dropped capabilities;
- isolated internal and external Docker networks;
- two independent Tor exits with HAProxy health checks and failover;
- an authenticated AES-256-XTS wallet vault using Argon2id and HMAC-SHA-256;
- pinned Monero source revisions and targeted Alpine security updates;
- native `linux/amd64` and `linux/arm64` CI builds;
- vulnerability scanning of every final image before `latest` is published.

The scans block known fixable critical and high findings. They reduce exposure,
but do not prove that an image contains no unknown vulnerability or RCE.

The [Monero CI workflow](https://github.com/m0nokey/mgla/actions/workflows/monero.yml)
always opens the list of runs; the newest run is at the top. Open it and select
Summary to see the per-image vulnerability table. The current Trivy v0.74.0
run is [run #18](https://github.com/m0nokey/mgla/actions/runs/34924206682).
Full reports for all severity levels are published in
[GitHub Code scanning](https://github.com/m0nokey/mgla/security/code-scanning).
Each run also provides downloadable SARIF artifacts for both architectures.

## Project Layout

```text
run.sh                       Project launcher and wallet menu
monero/
├── monero-cli.sh            Monero lifecycle controller
├── compose.yaml             Isolated four-service stack
└── docker/
    ├── exit/                Tor exit image, scripts and torrc template
    ├── haproxy/             HAProxy image, scripts and config template
    └── monero/              Monero CLI, Rust vault, and wallet launcher
```

See `monero/README.md` for module-specific details.
