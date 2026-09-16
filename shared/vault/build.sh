#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
cargo test --release --locked
cargo build --release --locked
strip --strip-unneeded target/release/mgla-vault
