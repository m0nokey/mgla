# mgla

`mgla` is a privacy-oriented container workspace for cryptocurrency CLI
wallets. Each wallet is an independent module with a shared onion-only
transport layer.

Current module:

- `monero/` — Monero CLI wallet, Tor exits, HAProxy SOCKS5h, named host wallets.

Planned module:

- `bitcoin/` — Bitcoin CLI wallet using the same reusable Tor transport.

The project is designed for reproducible builds, least-privilege containers,
pinned source revisions, dynamic Docker subnets, CI vulnerability checks, and
optional multi-architecture image publication to GHCR after successful scans.
Wallet keys and host wallet directories are never copied into images or the
repository.
