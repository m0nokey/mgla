"""Limit the Alpine configuration to the applets used by the runtime scripts."""

import re
import sys
from pathlib import Path

source = Path.cwd()
allowed = set(Path(sys.argv[1]).read_text().splitlines())
applet_options = {}
for path in source.rglob("*.c"):
    for declaration in re.findall(r"^//applet:IF_.*$", path.read_text(errors="replace"), re.M):
        match = re.fullmatch(
            r"//applet:IF_(\w+)\(\s*(?:IF_\w+\(\s*)*APPLET\w*\(\s*([^,]+),.*",
            declaration,
        )
        assert match, f"Unrecognized applet declaration in {path}: {declaration}"
        option, applet = match.groups()
        applet_options.setdefault(option, set()).add(applet.strip().strip('"'))
assert {"ASH", "WGET", "TEST1", "INSMOD", "MODPROBE", "DEPMOD"}.issubset(applet_options), (
    "Missing BusyBox applet declarations"
)
disabled = {option for option, applets in applet_options.items() if not applets & allowed}
# The dispatcher implements --list even when it is absent from the applet table.
disabled.discard("BUSYBOX")
disabled.update({"FEATURE_UTMP", "FEATURE_WTMP", "MODPROBE_SMALL"})
config = source / ".config"
lines = config.read_text().splitlines()
for index, line in enumerate(lines):
    if line.startswith("CONFIG_"):
        name = line.removeprefix("CONFIG_").partition("=")[0]
        if name in disabled:
            lines[index] = f"# CONFIG_{name} is not set"
config.write_text("\n".join(lines) + "\n")
