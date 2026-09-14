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
mkdir mgla \
&& curl -fsSL --proto '=https' "https://github.com/m0nokey/mgla/archive/refs/heads/main.tar.gz" \
| tar -xz -C mgla --strip-components=1 \
&& cd mgla \
&& bash run.sh
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
                  mgla-exit-a                 mgla-exit-b
                         ▲                         ▲
                         └────────────┬────────────┘
                                      │
                    mgla-haproxy (Tor SOCKS relay)
                                      ▲
                                      │ internal_network only
                                      │
                                mgla-monero
```

`mgla-monero` is attached only to Docker's internal network and has no direct
Internet route. `mgla-haproxy` also has no external network attachment; its
backend pool contains only the two Tor exit containers. The exit containers are
the only services attached to the external bridge.

Docker subnets and container addresses are generated at every launch and passed
to Compose at runtime. They are not embedded in the published images.

## Wallet Storage

Wallet files stay on the host. The default directory is:

```text
$HOME/Downloads/Monero/wallets
```

Use another absolute directory when needed:

```bash
WALLET_HOST_DIR=/absolute/path/to/wallets bash run.sh
```

## Security Model

The project uses:

- non-root, read-only containers with dropped capabilities;
- isolated internal and external Docker networks;
- two independent Tor exits with HAProxy health checks and failover;
- pinned Monero source revisions and targeted Alpine security updates;
- native `linux/amd64` and `linux/arm64` CI builds;
- vulnerability scanning of every final image before `latest` is published.

The scans block known fixable critical and high findings. They reduce exposure,
but do not prove that an image contains no unknown vulnerability or RCE.

## Project Layout

```text
run.sh                       Project launcher and wallet menu
monero/
├── monero-cli.sh            Monero lifecycle controller
├── compose.yaml             Isolated four-service stack
└── docker/
    ├── exit/                Tor exit image, scripts and torrc template
    ├── haproxy/             HAProxy image, scripts and config template
    └── monero/              Monero CLI source build and wallet launcher
```

See `monero/README.md` for module-specific details.
