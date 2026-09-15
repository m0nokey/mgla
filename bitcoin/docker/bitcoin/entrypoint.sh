#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

exec "$@"
