#!/usr/bin/env python3
"""Write the Bitcoin module Trivy table to the GitHub Actions summary."""

from collections import Counter
import json
import os
from pathlib import Path


SEVERITIES = ("UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL")
IMAGE_ORDER = ("exit", "haproxy", "bitcoin")


def classify(value):
    if value is None:
        return None

    text = str(value).strip().upper()
    if text in SEVERITIES:
        return text

    try:
        score = float(text)
    except ValueError:
        return None

    if score >= 9.0:
        return "CRITICAL"
    if score >= 7.0:
        return "HIGH"
    if score >= 4.0:
        return "MEDIUM"
    if score > 0.0:
        return "LOW"
    return "UNKNOWN"


def result_severity(result, rules):
    properties = result.get("properties", {})
    rule = rules.get(result.get("ruleId"), {})
    rule_properties = rule.get("properties", {})

    for key in ("severity", "security-severity"):
        severity = classify(properties.get(key))
        if severity:
            return severity
        severity = classify(rule_properties.get(key))
        if severity:
            return severity

    return "UNKNOWN"


def load_counts(path):
    report = json.loads(path.read_text())
    counts = Counter()
    for run in report.get("runs", []):
        rules = {
            rule.get("id"): rule
            for rule in run.get("tool", {}).get("driver", {}).get("rules", [])
            if rule.get("id")
        }
        for result in run.get("results", []):
            counts[result_severity(result, rules)] += 1
    return counts


def main():
    reports = sorted(Path("trivy-reports").glob("*.sarif"))
    if not reports:
        raise SystemExit("No SARIF reports found")

    rows = []
    for path in reports:
        image, architecture = path.stem.rsplit("-", 1)
        counts = load_counts(path)
        total = sum(counts.values())
        rows.append((image, architecture, counts, total))

    def sort_key(row):
        image, architecture, _, _ = row
        image_index = IMAGE_ORDER.index(image) if image in IMAGE_ORDER else len(IMAGE_ORDER)
        return image_index, architecture

    rows.sort(key=sort_key)

    lines = [
        "## Container security summary",
        "",
        "| Image | Architecture | UNKNOWN | LOW | MEDIUM | HIGH | CRITICAL | Total |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for image, architecture, counts, total in rows:
        values = [str(counts.get(severity, 0)) for severity in SEVERITIES]
        line = f"| `{image}` | `{architecture}` | "
        lines.append(line + " | ".join(values) + f" | {total} |")

    lines.extend(
        (
            "",
            "Reports include OS and library vulnerabilities from Trivy. "
            "The blocking policy remains fixable HIGH and CRITICAL findings.",
            "",
        )
    )
    summary = "\n".join(lines)
    destination = os.environ.get("GITHUB_STEP_SUMMARY")
    if destination:
        with open(destination, "a", encoding="utf-8") as output:
            output.write(summary)
            output.write("\n")
    else:
        print(summary)


if __name__ == "__main__":
    main()
