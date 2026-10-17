# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| main    | :white_check_mark: |

## Reporting a Vulnerability

Nymbra is a local terminal emulator with **no network calls of any kind** (a stated non-functional requirement). It does not handle credentials, does not phone home, and has no updater or plugin surface today.

If you believe you have found a security issue — for example, a parser bug reachable from untrusted terminal output that could crash or corrupt memory — please:

1. Open a [bug report](https://github.com/Davin-X/nymbra/issues/new?template=bug_report.md) describing the issue and the program/bytes that trigger it.
2. Include `make check` output and the raw byte capture if relevant.
3. Do **not** disclose the issue publicly until it has been triaged.

We will acknowledge reports within 5 business days and aim to ship a fix in the next release. There is no bug bounty program at this time.