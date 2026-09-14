# mgla

`mgla` is a privacy-oriented container workspace for cryptocurrency CLI
wallets. Each wallet is an independent module with a shared onion-only
transport layer.

Current module:

- `monero/` — Monero CLI wallet, Tor exits, HAProxy SOCKS5h, named host wallets.

Planned module:

- `bitcoin/` — Bitcoin CLI wallet using the same reusable Tor transport.

## Quick Start

For normal use, download the latest stable release from the GitHub Releases page.
Release archives include a SHA-256 checksum and are the recommended way to run
`mgla`.

```bash
curl -fsSL --proto '=https' -O "https://github.com/m0nokey/mgla/releases/latest/download/mgla-latest.tar.gz" \
&& curl -fsSL --proto '=https' -O "https://github.com/m0nokey/mgla/releases/latest/download/SHA256SUMS" \
&& grep -F "mgla-latest.tar.gz" SHA256SUMS | sha256sum -c - \
&& tar -xzf mgla-latest.tar.gz \
&& cd "$(tar -tzf mgla-latest.tar.gz | sed -n '1s#/.*##p')" \
&& bash run.sh
```

The `releases/latest` link always points to the newest stable release. The
README does not need to be changed for every patch release.

For development and testing, use the `main` branch instead:

```bash
git clone https://github.com/m0nokey/mgla.git
cd mgla
bash run.sh
```

Without Git:

```bash
curl -fsSL https://github.com/m0nokey/mgla/archive/refs/heads/main.tar.gz | tar -xz
mv mgla-main mgla
cd mgla
bash run.sh
```

The main menu is owned by `run.sh`; it selects a wallet scenario such as Monero.
The root `monero-cli.sh` remains only as a compatibility wrapper for the Monero
module. The normal Monero flow pulls the latest multi-architecture images from
GHCR. Use `IMAGE_MODE=build` when a local source build is required.

The project is designed for reproducible builds, least-privilege containers,
pinned source revisions, dynamic Docker subnets, CI vulnerability checks, and
optional multi-architecture image publication to GHCR after successful scans.
Wallet keys and host wallet directories are never copied into images or the
repository.
