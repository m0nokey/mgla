#!/usr/bin/env python3
"""Check direct and Tor-routed connectivity without adding curl to the image."""

import asyncio
import json
import sys
from urllib.request import ProxyHandler, build_opener


CHECK_URL = "https://check.torproject.org/api/ip"
DIRECT_TIMEOUT = 8
TOR_TIMEOUT = 15


def direct_probe():
    opener = build_opener(ProxyHandler({}))

    try:
        with opener.open(CHECK_URL, timeout=DIRECT_TIMEOUT) as response:
            body = response.read(4096).decode("utf-8", "replace")
    except Exception:
        return 1

    print(body)
    return 0


async def tor_probe(host, port):
    from aiohttp import ClientSession, ClientTimeout
    from aiohttp_socks import ProxyConnector

    connector = ProxyConnector.from_url(f"socks5://{host}:{port}")
    timeout = ClientTimeout(total=TOR_TIMEOUT)

    try:
        async with ClientSession(
            connector=connector,
            timeout=timeout,
        ) as session:
            async with session.get(CHECK_URL) as response:
                if response.status != 200:
                    return 1
                body = await response.text()
    except Exception:
        return 1

    try:
        result = json.loads(body)
    except json.JSONDecodeError:
        return 1

    if result.get("IsTor") is not True:
        return 1

    print(json.dumps(result, separators=(",", ":")))
    return 0


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "direct":
        return direct_probe()

    if len(sys.argv) == 4 and sys.argv[1] == "tor":
        host = sys.argv[2]
        try:
            port = int(sys.argv[3])
        except ValueError:
            return 2

        if not host or not 1 <= port <= 65535:
            return 2
        return asyncio.run(tor_probe(host, port))

    print(
        f"usage: {sys.argv[0]} direct | tor HOST PORT",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
