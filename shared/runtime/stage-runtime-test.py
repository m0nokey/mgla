"""Verify dependency closure, source-root symlinks, ownership, and inventory."""

import importlib.util
import json
from pathlib import Path
import stat
import subprocess

spec = importlib.util.spec_from_file_location("stage_runtime", Path(__file__).with_name("stage-runtime.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

runtime = module.RuntimeTree("/source", "/runtime")
assert str(runtime.resolve("/../../usr")) == "/usr"
assert str(runtime.entry_path("/..")) == "/"
runtime.add("/bin/sh")
runtime.add("/usr/local/bin/probe")
runtime.add("/usr/local/bin/curl")
runtime.add("/etc/os-release")
runtime.add("/var/lib/fixture")
runtime.finish("fixture")

# This chroot has no /proc/self/exe; musl then uses argv[0] for $ORIGIN.
# Check RPATH via the real path and absolute-alias execution independently.
assert subprocess.check_output(["chroot", "/runtime", "/opt/fixture/probe"], text=True).strip() == "42"
subprocess.run(["chroot", "/runtime", "/usr/local/bin/curl", "--version"], check=True)
assert (Path("/runtime/usr/local/bin/probe").is_symlink())
attributes = Path("/runtime/var/lib/fixture").stat()
assert (attributes.st_uid, attributes.st_gid, stat.S_IMODE(attributes.st_mode)) == (1000, 4242, 0o700)
manifest = json.loads(Path("/runtime/usr/share/mgla/runtime-packages.json").read_text())
assert "curl" in manifest["source_packages"]
assert "musl" in manifest["source_packages"]
assert "apk-tools" not in manifest["source_packages"]
assert not Path("/runtime/sbin/apk").exists()
assert not Path("/runtime/usr/bin/lddtree").exists()

# A missing DT_NEEDED library must fail assembly instead of producing an image.
Path("/source/opt/fixture/lib/libfixture.so.1").unlink()
broken = module.RuntimeTree("/source", "/broken")
broken.add("/usr/local/bin/probe")
try:
    broken.collect_dependencies()
except RuntimeError as error:
    assert "libfixture.so.1" in str(error), error
else:
    raise SystemExit("Assembly accepted a missing shared library")
print("Scratch assembly: RPATH, absolute symlinks, ownership, inventory, and missing-library checks passed")
