#!/usr/bin/env python3
"""Render read-only Electrum wallet data for the Bitcoin terminal UI."""

import json
import sys
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation


COIN = Decimal("100000000")


def load_json():
    try:
        return json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        print("[error] Electrum returned invalid JSON.", file=sys.stderr)
        return None


def scalar(value):
    if isinstance(value, dict):
        return value.get("value", value.get("amount", value.get("satoshis")))
    return value


def integer(value):
    value = scalar(value)
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def history_sats(item, key):
    return integer(item.get(key))


def btc_from_sats(value):
    return Decimal(value) / COIN


def btc_text(value, sign=False):
    value = Decimal(value)
    result = format(value, ".8f")
    if sign and value > 0:
        result = "+" + result
    return result


def date_text(timestamp):
    timestamp = scalar(timestamp)
    if timestamp in (None, "", 0):
        return "-"
    try:
        return datetime.fromtimestamp(float(timestamp), tz=timezone.utc).strftime("%Y-%m-%d %H:%M")
    except (TypeError, ValueError, OverflowError):
        return "-"


def label_text(value):
    if value is None:
        return ""
    value = str(value)
    if value in ("", "''", '""'):
        return ""
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def history_status(item):
    height = integer(item.get("height"))
    confirmations = integer(item.get("confirmations"))
    if height is not None and height < 0:
        return "LOCAL"
    if (confirmations is not None and confirmations > 0) or (height is not None and height > 0):
        if confirmations is None:
            return "CONFIRMED"
        return f"CONFIRMED ({confirmations} conf)"
    if height == 0 or confirmations == 0:
        return "PENDING"
    return "UNKNOWN"


def render_history(data):
    if not isinstance(data, list):
        print("[error] Electrum returned an unexpected history format.", file=sys.stderr)
        return 1
    if not data:
        print("No on-chain transactions found.")
        print("This is normal for a new wallet or before its first transaction.")
        return 0

    print(f"Transactions: {len(data)}")
    print()
    for index, item in enumerate(data, start=1):
        if not isinstance(item, dict):
            continue
        amount = history_sats(item, "amount_sat")
        fee = history_sats(item, "fee_sat")
        amount_text = "unknown" if amount is None else btc_text(btc_from_sats(amount), sign=True)
        status = history_status(item)
        print(f"{index:02d}. {status}")
        print(f"    Date:   {date_text(item.get('timestamp'))}")
        print(f"    Amount: {amount_text} BTC")
        if fee is None:
            print("    Fee:    -")
        else:
            print(f"    Fee:    {btc_text(btc_from_sats(fee))} BTC")
        if item.get("txid"):
            print(f"    TXID:   {item['txid']}")
        label = label_text(item.get("label"))
        if label:
            print(f"    Label:  {label}")
        balance = history_sats(item, "bc_balance")
        if balance is not None:
            print(f"    Balance after: {btc_text(btc_from_sats(balance))} BTC")
        print()
    return 0


def address_row(entry):
    if isinstance(entry, str):
        return entry, None, ""
    if isinstance(entry, (list, tuple)):
        if not entry:
            return "", None, ""
        return str(entry[0]), entry[1] if len(entry) > 1 else None, entry[2] if len(entry) > 2 else ""
    if isinstance(entry, dict):
        address = entry.get("address", entry.get("addr", ""))
        balance = entry.get("balance", entry.get("balance_btc", entry.get("value")))
        label = entry.get("label", "")
        return str(address), balance, label
    return "", None, ""


def address_set(entries):
    if not isinstance(entries, list):
        return set()
    return {address_row(entry)[0] for entry in entries if address_row(entry)[0]}


def address_balance(value):
    if value is None:
        return "-"
    value = scalar(value)
    try:
        return format(Decimal(str(value)), ".8f")
    except (InvalidOperation, TypeError, ValueError):
        return "-"


def render_address_section(title, entries, unused):
    if not isinstance(entries, list):
        print(f"{title}: unavailable")
        return
    print(f"{title} addresses: {len(entries)}")
    if not entries:
        print("  None")
        print()
        return
    for index, entry in enumerate(entries, start=1):
        address, balance, label = address_row(entry)
        if not address:
            continue
        status = "unused" if address in unused else "used"
        print(f"{index:02d}. {status:<6} {address_balance(balance)} BTC")
        print(f"    {address}")
        label = label_text(label)
        if label:
            print(f"    Label: {label}")
    print()


def render_addresses(data):
    if not isinstance(data, dict):
        print("[error] Electrum returned an unexpected address format.", file=sys.stderr)
        return 1
    render_address_section("Receiving", data.get("receiving"), address_set(data.get("receiving_unused")))
    render_address_section("Change", data.get("change"), address_set(data.get("change_unused")))
    return 0


def utxo_sats(item):
    if "value_sats" in item:
        return integer(item.get("value_sats"))
    value = item.get("value")
    if isinstance(value, int):
        return value
    try:
        return int(Decimal(str(value)) * COIN)
    except (InvalidOperation, TypeError, ValueError):
        return None


def utxo_status(item):
    height = integer(item.get("height"))
    if height is not None and height < 0:
        return "LOCAL"
    if height == 0:
        return "PENDING"
    if height is not None and height > 0:
        return f"CONFIRMED @ {height}"
    return "UNKNOWN"


def utxo_outpoint(item):
    if item.get("prevout"):
        return str(item["prevout"])
    txid = item.get("prevout_hash", item.get("tx_hash", item.get("txid", "")))
    index = item.get("prevout_n", item.get("tx_pos", item.get("vout")))
    if txid and index is not None:
        return f"{txid}:{index}"
    return "-"


def render_utxo(data):
    if not isinstance(data, list):
        print("[error] Electrum returned an unexpected UTXO format.", file=sys.stderr)
        return 1
    if not data:
        print("No unspent outputs found.")
        return 0

    total = sum((utxo_sats(item) or 0 for item in data if isinstance(item, dict)), 0)
    print(f"UTXOs: {len(data)}")
    print(f"Total: {btc_text(btc_from_sats(total))} BTC")
    print()
    for index, item in enumerate(data, start=1):
        if not isinstance(item, dict):
            continue
        amount = utxo_sats(item)
        amount_text = "unknown" if amount is None else btc_text(btc_from_sats(amount))
        print(f"{index:02d}. {amount_text} BTC - {utxo_status(item)}")
        print(f"    Outpoint: {utxo_outpoint(item)}")
        if item.get("address"):
            print(f"    Address:  {item['address']}")
        if item.get("is_frozen") is not None:
            print(f"    Frozen:   {'yes' if item['is_frozen'] else 'no'}")
    return 0


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in {"history", "addresses", "utxo"}:
        print("usage: wallet-view.py {history|addresses|utxo}", file=sys.stderr)
        return 2
    data = load_json()
    if data is None:
        return 1
    renderers = {"history": render_history, "addresses": render_addresses, "utxo": render_utxo}
    return renderers[sys.argv[1]](data)


if __name__ == "__main__":
    raise SystemExit(main())
