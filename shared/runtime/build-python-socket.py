"""Rebuild patched native modules against the matching Alpine Python ABI."""

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

include = Path(sysconfig.get_path("include"))
module_dir = Path(sysconfig.get_config_var("DESTSHARED"))
extension = sysconfig.get_config_var("EXT_SUFFIX")
config_dir = Path("/build-config")
metadata_dir = Path("/out/usr/share/mgla")
metadata_dir.mkdir(parents=True, exist_ok=True)


def rebuild(module, filename, patch, test, manifest_name, cve, upstream_fix, libraries=()):
    installed = module_dir / (module + extension)
    output = Path("/out") / installed.relative_to("/")
    output.parent.mkdir(parents=True, exist_ok=True)
    command = shlex.split(sysconfig.get_config_var("LDSHARED"))
    command += shlex.split(sysconfig.get_config_var("CFLAGS") or "")
    command += [
        "-O2", "-fPIC", "-Werror=implicit-function-declaration",
        f"-I{include}", f"-I{include / 'internal'}", f"-I{source / 'Modules'}",
        str(source / "Modules" / filename), "-o", str(output), *libraries,
    ]
    subprocess.run(command, check=True)

    original_hash = hashlib.sha256(installed.read_bytes()).hexdigest()
    # The build interpreter may already have mapped the old module.
    replacement = installed.with_name(installed.name + ".new")
    shutil.copyfile(output, replacement)
    os.replace(replacement, installed)
    subprocess.run([sys.executable, "-I", str(config_dir / test)], check=True)

    manifest = {
        "cve": cve,
        "python_version": version,
        "python_package": subprocess.check_output(["apk", "info", "-v", "python3"], text=True).strip(),
        "soabi": sysconfig.get_config_var("SOABI"),
        "upstream_fix": upstream_fix,
        "source_sha512": os.environ["PYTHON_ARCHIVE_SHA512"],
        "patch_sha256": hashlib.sha256((config_dir / patch).read_bytes()).hexdigest(),
        "original_module_sha256": original_hash,
        "module_sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
    }
    (metadata_dir / manifest_name).write_text(json.dumps(manifest, indent=2) + "\n")


rebuild(
    "_socket", "socketmodule.c", "socket-getaddrinfo.patch", "verify-socket.py",
    "python-socket-build.json", "CVE-2026-116566", "131a3a66c5f400b588f9fd2732a5ed4e89623ee3",
)
rebuild(
    "_hashlib", "_hashopenssl.c", "hashlib-fips.patch", "verify-hashlib-fips.py",
    "python-hashlib-build.json", "CVE-2026-119170", "7d9da9208fc3dc126bebca6844dfe312afc43c34",
    libraries=("-lcrypto",),
)
