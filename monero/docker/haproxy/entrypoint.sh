#!/bin/sh
set -eu

config="${HAPROXY_CONFIG:-/tmp/haproxy.cfg}"

/usr/local/bin/render-haproxy-config
exec haproxy -f "$config" -db
