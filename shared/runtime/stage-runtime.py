"""Assemble a scratch filesystem from explicit roots and their ELF dependencies."""

import argparse
from collections import deque
import json
import os
from pathlib import Path, PurePosixPath
import runpy
import shutil
import stat


SEARCH_PATH = ("/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin")


class RuntimeTree:
    def __init__(self, source, destination):
        self.source = Path(source).resolve()
        self.destination = Path(destination).resolve()
        if (self.source.is_relative_to(self.destination)
                or self.destination.is_relative_to(self.source)):
            raise ValueError("Source and destination must be separate filesystem trees")
        if self.destination.exists() and any(self.destination.iterdir()):
            raise ValueError("Destination must be empty")
        self.destination.mkdir(parents=True, exist_ok=True)
        self.entries = set()
        self.trees = set()
        self.elfs = deque()
        self.elf_count = 0

    def resolve(self, path):
        """Resolve absolute symlinks inside the source, never on the build host."""
        path = PurePosixPath(path)
        if not path.is_absolute():
            raise ValueError(f"Expected an image-absolute path: {path}")
        remaining = deque(path.parts[1:])
        resolved = []
        links = 0
        while remaining:
            part = remaining.popleft()
            if part in ("", "."):
                continue
            if part == "..":
                if resolved:
                    resolved.pop()
                continue
            candidate = self.source.joinpath(*resolved, part)
            if candidate.is_symlink():
                links += 1
                if links > 40:
                    raise ValueError(f"Symlink loop: {path}")
                target = PurePosixPath(os.readlink(candidate))
                if target.is_absolute():
                    resolved = []
                    parts = target.parts[1:]
                else:
                    parts = target.parts
                remaining.extendleft(reversed(parts))
            else:
                resolved.append(part)
        return PurePosixPath("/", *resolved)

    def entry_path(self, path):
        path = PurePosixPath(path)
        if path == PurePosixPath("/") or path.name == "..":
            return self.resolve(path)
        return self.resolve(path.parent) / path.name

    def source_path(self, path):
        return self.source.joinpath(*self.entry_path(path).parts[1:])

    def exists(self, path):
        return os.path.lexists(self.source_path(path))

    def add(self, path):
        path = PurePosixPath(path)
        entry = self.entry_path(path)
        if str(entry) in self.entries:
            return
        if path != PurePosixPath("/"):
            self.add(path.parent)
        original = self.source.joinpath(*entry.parts[1:])
        target = self.destination.joinpath(*entry.parts[1:])
        attributes = original.lstat()
        self.entries.add(str(entry))
        if stat.S_ISLNK(attributes.st_mode):
            link = os.readlink(original)
            target.symlink_to(link)
            referent = PurePosixPath(link)
            self.add(referent if referent.is_absolute() else entry.parent / referent)
        elif stat.S_ISDIR(attributes.st_mode):
            target.mkdir(exist_ok=True)
            shutil.copystat(original, target, follow_symlinks=False)
        elif stat.S_ISREG(attributes.st_mode):
            shutil.copy2(original, target)
            with original.open("rb") as stream:
                header = stream.read(4096)
            if header.startswith(b"\x7fELF"):
                self.elfs.append(str(entry))
            elif attributes.st_mode & 0o111 and header.startswith(b"#!"):
                words = header.splitlines()[0][2:].decode().split()
                self.add(words[0])
                if PurePosixPath(words[0]).name == "env":
                    command = next(word for word in words[1:] if not word.startswith("-"))
                    self.command(command)
        else:
            raise ValueError(f"Special file must be supplied by the container runtime: {path}")
        os.chown(target, attributes.st_uid, attributes.st_gid, follow_symlinks=False)

    def tree(self, path):
        self.add(path)
        directory = self.resolve(path)
        if str(directory) in self.trees:
            return
        self.trees.add(str(directory))
        original = self.source.joinpath(*directory.parts[1:])
        if original.is_dir():
            for child in sorted(original.iterdir()):
                if child.name.endswith((".orig", ".rej")):
                    continue
                logical = directory / child.name
                if self.source.joinpath(*self.resolve(logical).parts[1:]).is_dir():
                    self.tree(logical)
                else:
                    self.add(logical)

    def optional(self, path, tree=False):
        if self.exists(path):
            (self.tree if tree else self.add)(path)

    def command(self, name):
        for directory in SEARCH_PATH:
            path = PurePosixPath(directory) / name
            if self.exists(path):
                self.add(path)
                return
        raise FileNotFoundError(f"Required runtime command is missing: {name}")

    def collect_dependencies(self):
        scanner = runpy.run_path("/usr/bin/lddtreepax")
        parse_paths = scanner["ParseLdPaths"]

        def image_paths(value, root="", cwd=None, path=""):
            # pax-utils 1.3.9 otherwise prefixes --root twice for $ORIGIN.
            # Give expansion the image path, while file reads keep the host path.
            prefix = root.rstrip("/")
            if prefix and path.startswith(prefix + "/"):
                path = path[len(prefix):]
            return parse_paths(value, root=root, cwd=cwd, path=path)

        scanner["ParseELF"].__globals__["ParseLdPaths"] = image_paths
        root = str(self.source) + "/"
        search = scanner["LoadLdpaths"](root)
        search["env"] = []  # Never resolve against the assembler's environment.
        # A shared object has no PT_INTERP from which lddtree can infer these.
        # Read musl's own configuration, or use its documented default paths.
        musl_paths = list(self.source.glob("etc/ld-musl-*.path"))
        if len(musl_paths) > 1:
            raise RuntimeError(f"Ambiguous musl search path: {musl_paths}")
        directories = (musl_paths[0].read_text().replace("\n", ":").split(":")
                       if musl_paths else ["/lib", "/usr/local/lib", "/usr/lib"])
        for directory in directories:
            directory = directory.strip()
            if directory and not directory.startswith("#"):
                if not directory.startswith("/"):
                    raise RuntimeError(f"Relative musl library path: {directory}")
                search["conf"].append(str(self.source_path(directory)))
        while self.elfs:
            path = self.elfs.popleft()
            result = scanner["ParseELF"](str(self.source_path(path)), root=root, ldpaths=search)
            self.elf_count += 1
            for name, library in result["libs"].items():
                line = library["path"]
                if line is None:
                    raise RuntimeError(f"Unresolved dependency of {path}: {name}")
                dependency = Path(line)
                if not dependency.is_absolute() or not dependency.is_relative_to(self.source):
                    raise RuntimeError(f"Unresolved or out-of-tree dependency of {path}: {line}")
                self.add("/" + dependency.relative_to(self.source).as_posix())

    def finish(self, profile):
        self.collect_dependencies()
        inventory = self.source_path("/lib/apk/db/installed").read_text()
        records = []
        packages = {}
        for record in inventory.strip().split("\n\n"):
            directory = ""
            fields = {}
            selected = False
            for line in record.splitlines():
                if line.startswith("F:"):
                    directory = line[2:]
                elif line.startswith("R:"):
                    entry = self.entry_path("/" + directory + "/" + line[2:])
                    selected |= str(entry) in self.entries
                elif len(line) > 1 and line[1] == ":":
                    fields.setdefault(line[0], line[2:])
            if selected:
                records.append(record)
                packages[fields["P"]] = fields["V"]
        metadata = self.destination.joinpath(*self.entry_path("/lib/apk/db/installed").parts[1:])
        metadata.parent.mkdir(parents=True, exist_ok=True)
        metadata.write_text("\n\n".join(records) + "\n\n")
        manifest = self.destination.joinpath(*self.entry_path("/usr/share/mgla/runtime-packages.json").parts[1:])
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text(json.dumps({
            "profile": profile,
            "elf_files_checked": self.elf_count,
            "source_packages": dict(sorted(packages.items())),
            "selected_paths": sorted(self.entries),
        }, indent=2) + "\n")
        print(f"Staged {profile}: {len(self.entries)} paths, {self.elf_count} ELF files, {len(packages)} source packages")


def configure(runtime, profile):
    runtime.add("/bin/busybox")
    busybox = runtime.resolve("/bin/busybox")
    for directory in SEARCH_PATH:
        if not runtime.exists(directory):
            continue
        original = runtime.source.joinpath(*runtime.resolve(directory).parts[1:])
        for path in original.iterdir():
            logical = PurePosixPath(directory) / path.name
            if path.is_symlink() and runtime.resolve(logical) == busybox:
                runtime.add(logical)
    for path in ("/etc/passwd", "/etc/group", "/etc/os-release", "/etc/alpine-release",
                 "/etc/services", "/etc/protocols", "/etc/nsswitch.conf", "/etc/inputrc",
                 "/etc/localtime", "/etc/timezone", "/usr/share/zoneinfo/UTC"):
        runtime.optional(path)
    for path in ("/etc/ssl", "/etc/terminfo", "/usr/share/terminfo",
                 "/usr/lib/ossl-modules", "/usr/share/mgla"):
        runtime.optional(path, tree=True)
    for path in ("/tmp", "/run", "/dev", "/proc", "/sys"):
        runtime.optional(path)
    for path in runtime.source.glob("etc/ld-musl-*.path"):
        runtime.add("/" + path.relative_to(runtime.source).as_posix())

    programs = {
        "monero": ("bash", "curl", "monero-wallet-cli"),
        "bitcoin": ("bash", "curl", "python3"),
        "exit": ("tor", "nyx", "python3", "xxd", "ps", "pgrep"),
        "haproxy": ("haproxy", "python3", "xxd"),
    }
    for program in programs[profile]:
        runtime.command(program)
    if profile != "monero":
        versions = list((runtime.source / "usr/lib").glob("python3.*"))
        if len(versions) != 1:
            raise RuntimeError(f"Expected one Python standard library, found {versions}")
        runtime.tree("/" + versions[0].relative_to(runtime.source).as_posix())
    if profile in ("monero", "bitcoin"):
        runtime.tree("/opt")
        for path in (("/monero", "/monero/wallets", "/monero/vault-store", "/tmp/home")
                     if profile == "monero" else
                     ("/bitcoin", "/bitcoin/vault-store", "/home/electrum", "/home/electrum/.electrum")):
            runtime.add(path)
        if profile == "bitcoin":
            runtime.command("entrypoint")
            libraries = list(runtime.source.glob("usr/lib/libsecp256k1.so*"))
            if not libraries:
                raise FileNotFoundError("Electrum's dynamically loaded libsecp256k1 is missing")
            for path in libraries:
                runtime.add("/" + path.relative_to(runtime.source).as_posix())
    else:
        runtime.add("/usr/local/bin/entrypoint-docker.sh")
        runtime.add("/usr/local/bin/tor-control")
        if profile == "exit":
            runtime.add("/usr/local/bin/healthcheck")
            runtime.add("/etc/tor/torrc.template")
            runtime.add("/var/lib/tor")
            runtime.add("/run/tor")
            runtime.optional("/usr/share/tor", tree=True)
            runtime.optional("/etc/nyx", tree=True)
        else:
            for path in ("/usr/local/bin/render-haproxy-config", "/usr/local/bin/exit_ready_check",
                         "/usr/bin/tor-control", "/etc/haproxy/haproxy.cfg.template"):
                runtime.add(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", choices=("exit", "haproxy", "monero", "bitcoin"))
    parser.add_argument("--source", default="/source")
    parser.add_argument("--output", default="/runtime")
    args = parser.parse_args()
    runtime = RuntimeTree(args.source, args.output)
    configure(runtime, args.profile)
    runtime.finish(args.profile)


if __name__ == "__main__":
    main()
