"""Record only the CVE dispositions verified against this image."""

import argparse
import json
import subprocess
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote


def check_image(image_id, entrypoint, *args, stdin=None):
    command = [
        "docker", "run", "--rm", "--network", "none", "--entrypoint", entrypoint,
    ]
    if stdin is not None:
        command.append("-i")
    command.extend([image_id, *args])
    result = subprocess.run(command, input=stdin, text=True, check=False)
    return result.returncode == 0


def verified_findings(image_id, image_name):
    findings = {}
    if check_image(
        image_id, "/bin/sh", "-ec",
        'applets="$(busybox --list)"; ! echo "$applets" | grep -qx wget && ! command -v wget',
    ):
        for package in ("busybox", "busybox-binsh", "ssl_client"):
            findings[("CVE-2025-60876", package, "1.37.0-r31")] = (
                "not_affected",
                "The BusyBox wget applet is disabled and no wget command is installed.",
            )

    if image_name != "monero":
        if check_image(image_id, "/bin/sh", "-ec", "! command -v sqlite3"):
            findings[("CVE-2026-119586", "sqlite-libs", "3.54.1-r0")] = (
                "not_affected",
                "The SQLite command-line shell containing .recover is absent.",
            )

        test = Path(__file__).resolve().parents[1] / "runtime" / "verify-python.py"
        if check_image(image_id, "/usr/bin/python3", "-I", "-", stdin=test.read_text()):
            for cve, fix in (
                ("CVE-2025-15367", "POP3 commands reject control characters."),
                ("CVE-2026-103995", "HTTP chunk sizes reject non-hex framing."),
            ):
                findings[(cve, "python3", "3.14.10-r1")] = ("fixed", fix)

    return findings


def build_statements(matches, verified, product):
    components = defaultdict(set)
    for match in matches:
        package = match["artifact"]
        cve = match["vulnerability"]["id"]
        key = (cve, package["name"], package["version"])
        if package["type"] == "apk" and package.get("purl") and key in verified:
            status, explanation = verified[key]
            components[(cve, status, explanation)].add(package["purl"])

    statements = []
    for (cve, status, explanation), purls in sorted(components.items()):
        statement = {
            "vulnerability": {"name": cve},
            "products": [{
                "@id": product,
                "subcomponents": [{"@id": purl} for purl in sorted(purls)],
            }],
            "status": status,
        }
        if status == "not_affected":
            statement["justification"] = "vulnerable_code_not_present"
            statement["impact_statement"] = explanation
        else:
            statement["action_statement"] = explanation
        statements.append(statement)
    return statements


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image_name", choices=["bitcoin", "exit", "haproxy", "monero"])
    parser.add_argument("image_id")
    parser.add_argument("scan_tag")
    parser.add_argument("raw_report", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    repository, tag = args.scan_tag.rsplit(":", 1)
    name = repository.rsplit("/", 1)[1]
    report = json.loads(args.raw_report.read_text())
    # The local scan tag embeds the Docker image ID. Reject a report that does
    # not identify that exact local image and tag.
    source = report["source"]["target"]
    if source["imageID"] != args.image_id or args.scan_tag not in source["tags"]:
        raise SystemExit("Raw Grype report does not identify the verified image")

    product = f"pkg:oci/{name}?repository_url={quote(repository, safe='')}&tag={tag}"
    verified = verified_findings(args.image_id, args.image_name)
    statements = build_statements(report["matches"], verified, product)
    if statements:
        document = {
            "@context": "https://openvex.dev/ns/v0.2.0",
            "@id": f"https://github.com/m0nokey/mgla/vex/{name}/{tag}",
            "author": "mgla CI",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "version": 1,
            "statements": statements,
        }
        args.output.write_text(json.dumps(document, indent=2) + "\n")


if __name__ == "__main__":
    main()
