"""Rebuild only _socket against the installed, matching Alpine Python ABI."""

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import sysconfig

source = Path(sys.argv[1]).resolve()
version = os.environ["PYTHON_VERSION"]
if sys.version_info[:3] != tuple(map(int, version.split("."))):
    raise SystemExit("The source version must match the installed Python headers and runtime")

installed = Path(sysconfig.get_config_var("DESTSHARED")) / (
    "_socket" + sysconfig.get_config_var("EXT_SUFFIX")
)
output = Path("/out") / installed.relative_to("/")
output.parent.mkdir(parents=True, exist_ok=True)
include = Path(sysconfig.get_path("include"))
command = shlex.split(sysconfig.get_config_var("LDSHARED"))
command += shlex.split(sysconfig.get_config_var("CFLAGS") or "")
command += [
    "-O2", "-fPIC", "-Werror=implicit-function-declaration",
    f"-I{include}", f"-I{include / 'internal'}", f"-I{source / 'Modules'}",
    str(source / "Modules/socketmodule.c"), "-o", str(output),
]
subprocess.run(command, check=True)

original_hash = hashlib.sha256(installed.read_bytes()).hexdigest()
# Replace atomically: the build interpreter may already have mapped the old DSO.
replacement = installed.with_name(installed.name + ".new")
shutil.copyfile(output, replacement)
os.replace(replacement, installed)
subprocess.run([sys.executable, "-I", "/build-config/verify-socket.py"], check=True)

manifest = {
    "cve": "CVE-2026-116566",
    "python_version": version,
    "python_package": subprocess.check_output(["apk", "info", "-v", "python3"], text=True).strip(),
    "soabi": sysconfig.get_config_var("SOABI"),
    "upstream_fix": "131a3a66c5f400b588f9fd2732a5ed4e89623ee3",
    "source_sha512": os.environ["PYTHON_ARCHIVE_SHA512"],
    "patch_sha256": hashlib.sha256(Path("/build-config/socket-getaddrinfo.patch").read_bytes()).hexdigest(),
    "original_module_sha256": original_hash,
    "module_sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
}
metadata = Path("/out/usr/share/mgla/python-socket-build.json")
metadata.parent.mkdir(parents=True, exist_ok=True)
metadata.write_text(json.dumps(manifest, indent=2) + "\n")
