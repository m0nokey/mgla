"""Keep the Electrum command-line runtime and software-wallet plugins."""

import csv
import json
import shutil
import sysconfig
from pathlib import Path

site_packages = Path(sysconfig.get_path("purelib"))
electrum = site_packages / "electrum"
plugins = electrum / "plugins"
removed = []
for manifest in sorted(plugins.glob("*/manifest.json")):
    metadata = json.loads(manifest.read_text())
    keystore = metadata.get("registers_keystore", [])
    if keystore and keystore[0] == "hardware":
        removed.append(manifest.parent.name)
        shutil.rmtree(manifest.parent)
assert {"trezor", "ledger"}.issubset(removed), removed

# Keep the package entry point, which contains shared type definitions.
for child in (electrum / "gui").iterdir():
    if child.name != "__init__.py":
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()
for directory in (plugins, electrum / "hw_wallet"):
    for pattern in ("**/qt.py", "**/qml.py", "**/*.qml", "**/*.ui", "**/trezor_qt_*.py"):
        for path in directory.glob(pattern):
            path.unlink()

prefix = site_packages.parents[2]
for relative in (
    "share/applications/electrum.desktop",
    "share/pixmaps/electrum.png",
    "share/icons/hicolor/128x128/apps/electrum.png",
):
    (prefix / relative).unlink(missing_ok=True)

# Keep the installed package inventory consistent with the files retained.
record = next(site_packages.glob("[Ee]lectrum-*.dist-info/RECORD"))
with record.open(newline="") as stream:
    rows = [row for row in csv.reader(stream) if (site_packages / row[0]).exists()]
with record.open("w", newline="") as stream:
    csv.writer(stream).writerows(rows)
print("Removed hardware plugins:", ", ".join(removed))
