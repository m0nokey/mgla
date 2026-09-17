# Container security scan analysis

Audit date: 2026-09-17

The input reports are the local `security-reports-amd64/` and
`security-reports-arm64/` artifacts produced by the image scan job. The scan
used Trivy 0.74.0 and Grype 0.118.0 for the `exit`, `haproxy`, `monero`, and
`bitcoin` images.

## Result

Trivy reported no findings for either architecture. Grype reported the same
set of findings on amd64 and arm64:

| CVE | Package | Severity | Scope |
| --- | --- | --- | --- |
| CVE-2025-15367 | python3 3.14.7-r1 | Medium | Python runtime |
| CVE-2025-60876 | busybox 1.37.0-r31 and subpackages | Medium | All four images |
| CVE-2026-15310 | python3 3.14.7-r1 | Low | Python runtime |
| CVE-2026-15806 | python3 3.14.7-r1 | Medium | Python runtime |
| CVE-2026-17084 | python3 3.14.7-r1 | Medium | Python runtime |
| CVE-2026-19672 | python3 3.14.7-r1 | Medium | Python runtime |
| CVE-2026-58055 | nghttp2-libs 1.69.0-r0 | Medium | Bitcoin image only |
| CVE-2026-87910 | python3 3.14.7-r1 | Medium | Python runtime |

The BusyBox CVE appears three times per affected image because Grype reports
the `busybox`, `busybox-binsh`, and `ssl_client` APK records separately. The
full SARIF rules have an empty `Fix Version` field; therefore the full report
must not be interpreted as proof that every finding has a published Alpine
fix.

## Remediation applied

- The network stack is intentionally preserved. `python3`, Nyx,
  `procps-ng`, Tor, HAProxy, both `tor-control.py` helpers, and all existing
  health checks remain in place.
- All published wallet and network image stages now install the fixed Alpine
  edge BusyBox set `busybox`, `busybox-binsh`, and `ssl_client` at
  `1.38.0-r6`.
- The Bitcoin runtime now pins `nghttp2-libs=1.70.0-r0`, matching the package
  already used by the Monero runtime.

## Python status

At audit time Alpine v3.24 provides Python `3.14.7-r1`, while Alpine edge
provides `3.14.7-r0`. Switching the working network containers to edge would
therefore downgrade the package revision and would not be a security fix.
The Python findings require a newer Alpine/CPython security package when one
is published. The current code paths do not use `poplib`, `tarfile`, or
`HTTPPasswordMgr`; the network helpers use only Unix sockets, and Bitcoin's
diagnostic probe uses an unauthenticated HTTPS request. This reachability
information is recorded for review, while the complete SARIF findings remain
visible to CI.

After the image rebuild, rerun both scanners and inspect the fixable-only gate
output separately. The full reports must continue to be uploaded even when a
finding has no known fix.
