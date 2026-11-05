"""Limit the Alpine configuration to the applets used by the runtime scripts."""

import re
import sys
from pathlib import Path

source = Path.cwd()
allowed = set(Path(sys.argv[1]).read_text().splitlines())
applet_options = {}
for path in source.rglob("*.c"):
    for option, applet in re.findall(
        r"^//applet:IF_(\w+)\(\s*APPLET\w*\(\s*([^,]+),", path.read_text(errors="replace"), re.M
    ):
        applet_options.setdefault(option, set()).add(applet.strip().strip('"'))
assert {"ASH", "WGET", "TEST1"}.issubset(applet_options), "Missing BusyBox applet declarations"
disabled = {option for option, applets in applet_options.items() if not applets & allowed}
disabled.update({"FEATURE_UTMP", "FEATURE_WTMP"})
config = source / ".config"
lines = config.read_text().splitlines()
for index, line in enumerate(lines):
    if line.startswith("CONFIG_"):
        name = line.removeprefix("CONFIG_").partition("=")[0]
        if name in disabled:
            lines[index] = f"# CONFIG_{name} is not set"
config.write_text("\n".join(lines) + "\n")
