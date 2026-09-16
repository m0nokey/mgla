# mgla

`mgla` is a privacy-oriented Docker workspace for cryptocurrency CLI wallets.
The repository keeps the Tor transport and security tooling shared, while each
wallet remains an independent module that can be added without copying the
network stack.

## Quick start

Requirements: Docker Engine or Docker Desktop with Compose v2, and Bash.
Run the launcher as a normal user; root execution is rejected before Docker
starts so host files are not accidentally created with root ownership.

For normal use, download the repository and start the single project menu:

```bash
git clone https://github.com/m0nokey/mgla.git \
&& cd mgla \
&& bash ./run.sh
```

Without Git:

```bash
install -d -m 0700 mgla \
&& curl -fsSL --proto '=https' "https://github.com/m0nokey/mgla/archive/refs/heads/main.tar.gz" | tar -xz --strip-components=1 -C mgla \
&& cd mgla \
&& bash ./run.sh
```

The menu selects one wallet module at a time. The default mode pulls the
latest multi-architecture images from GHCR. To build locally instead:

```bash
IMAGE_MODE=build IMAGE_REGISTRY= IMAGE_TAG=local bash ./run.sh
```

Direct module launchers are available for development and CI:

```bash
bash monero/monero-cli.sh
bash bitcoin/bitcoin-cli.sh
```

## Architecture

The root `compose.yaml` contains the shared network and both wallet profiles.
`run.sh` selects a profile; the wallet-specific launcher generates fresh Docker
network ranges, starts the common transport, runs integration checks, and then
opens the selected CLI. The explicit container names are intentionally kept
short and stable for diagnostics and Nyx commands.

```text
                         Monero daemon / Electrum server (.onion)
                                           ▲
                                           │ Tor network
                         ┌─────────────────┴─────────────────┐
                         │                                   │
                       exit-a                              exit-b
                         ▲                                   ▲
                         └─────────────────┬─────────────────┘
                                           │ external_network
                              haproxy (SOCKS5/SOCKS5h relay)
                                           ▲
                                           │ internal_network only
                                           │
                          monero-cli / bitcoin-cli container
```

The wallet container has no direct Internet route and no published host port.
HAProxy is attached only to `internal_network`; the two Tor exits are the only
services attached to the external bridge. The application reaches the network
only through HAProxy and the Tor exits.

Docker subnets, gateways, and service addresses are generated at launch and
checked against the Docker networks already in use. They are runtime Compose
values and are not embedded in a published image. The `monero` and `bitcoin`
profiles use separate Compose project names so their network and volume names
are isolated; run them sequentially because the diagnostic container names are
shared by design.

## Repository layout

```text
.
├── README.md
├── run.sh
├── compose.yaml
├── network/
│   ├── exit/                    # shared hardened Alpine Tor image
│   └── haproxy/                 # shared internal SOCKS relay image
├── shared/
│   ├── ci/                      # shared security-summary.py
│   ├── lib/                     # shared runtime network generation
│   └── vault/                   # shared Rust encrypted-file utility
├── monero/
│   ├── Dockerfile
│   ├── monero-cli.sh
│   └── wallet-launcher.sh
├── bitcoin/
│   ├── Dockerfile
│   ├── bitcoin-cli.sh
│   ├── entrypoint.sh
│   ├── network-check.py
│   ├── requirements.lock
│   └── wallet-launcher.sh
└── .github/workflows/ci.yml
```

A new wallet-cli module should add its own image, launcher, and Compose profile
while reusing `network/`, `shared/lib/`, `shared/ci/`, and `compose.yaml`.

## Images and builds

The published images are:

```text
ghcr.io/m0nokey/mgla-exit:latest
ghcr.io/m0nokey/mgla-haproxy:latest
ghcr.io/m0nokey/mgla-monero:latest
ghcr.io/m0nokey/mgla-bitcoin:latest
```

Every image is built for `linux/amd64` and `linux/arm64`. Network images are
built once per architecture in CI and are reused by both wallet profiles.
Monero and the shared Rust vault are built from pinned inputs in Alpine 3.24
builders; Electrum is built from the signed, hash-pinned upstream archive in
an Alpine 3.24 builder. Compilers, package managers, signing tools, and build
caches are excluded from final images.

The shared Rust vault is compiled in the wallet builder stage and copied into
the final wallet image. It is not a runtime helper container and does not
create a block device. Only encrypted `.mgla` vault files remain on the host;
the decrypted shared vault exists only in the wallet container tmpfs.

## Wallet data

Shared encrypted vaults are stored in `$HOME/.mgla/` by default:

```text
$HOME/.mgla/
├── personal.mgla
└── savings.mgla
```

A single `.mgla` file can contain every wallet module:

```text
personal.mgla (encrypted)
├── monero/
└── bitcoin/
```

The selected launcher decrypts the complete archive into its private tmpfs,
uses only its own subdirectory, and repacks the complete archive on exit.
Wallet files are never committed and are ignored by Git. Module-specific
environment variables can override the host vault directory.

## Security and CI

The security objective is continuous, reproducible checking of image and
library dependencies while reducing direct-network and supply-chain exposure.
A scanner cannot prove that software has zero possible CVEs or RCEs, so all
findings remain reviewable even when the blocking policy is clean.

The single `mgla CI` workflow performs:

- native `linux/amd64` and `linux/arm64` builds;
- actionlint, ShellCheck, Compose, Python, Rust format, Clippy, and advisory checks;
- Tor integration and direct-route blocking tests for both wallet profiles;
- Trivy Dockerfile/Compose misconfiguration checks;
- Trivy repository secret scanning and OSV dependency scanning;
- CodeQL analysis for GitHub Actions, Python, and Rust;
- Trivy and Grype OS and library scans for all four final images;
- SARIF upload to **Security → Code scanning**;
- a per-image table in the workflow **Summary**;
- scheduled rescans of every published `latest` image.

The release gate blocks fixable `MEDIUM`, `HIGH`, and `CRITICAL` findings;
unfixed findings remain visible in the uploaded reports for review.

Validation jobs have read-only permissions. Only the isolated `publish` job on
`main` receives `packages: write`. It pushes architecture tags first, verifies
both source tags, and creates each multi-architecture `latest` manifest in the
same workflow. This prevents the two wallet pipelines from racing while
publishing the shared `exit` and `haproxy` tags.

- [Latest CI workflow](https://github.com/m0nokey/mgla/actions/workflows/ci.yml)
- [Workflow runs](https://github.com/m0nokey/mgla/actions)
- [Code scanning alerts](https://github.com/m0nokey/mgla/security/code-scanning)

See the module documentation:

- [Monero module](monero/README.md)
- [Bitcoin module](bitcoin/README.md)
