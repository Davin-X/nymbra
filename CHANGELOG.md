# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `Scripts/check-architecture.sh`, enforced in CI, to keep UI frameworks out of
  the core targets.
- `NymbraCheck`, a zero-dependency test harness, with a `TermBuffer` suite
  (14 checks).

### Fixed
- OSC sequences are now terminated by `BEL` or `ST` (`ESC \`) only. Previously
  the sequence ended at the first byte in `0x40...0x7E`, so an OSC payload
  containing a letter leaked into rendered output (for example, a window title
  of `My Title` rendered as `itle`). Regression test added.

### Documentation
- `README.md`, `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`, `CONTRIBUTING.md` and
  five ADRs.

## [0.0.1] — 2026-10-17

First scaffold. Not usable as a daily driver.

### Added
- PTY via `forkpty()`, with `TIOCSWINSZ` on resize (`CPTY`, `NymbraCore`).
- AppKit window with a CoreText-rendered character grid (`Nymbra`).
- Cell metrics measured from CoreText rather than assumed.
- Keyboard input and live window resize.
- `--pty-test` headless smoke test, suitable for CI.
- `Makefile` targets: `build`, `test`, `pty-test`, `check`, `clean`.

[Unreleased]: https://github.com/Davin-X/nymbra/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/Davin-X/nymbra/releases/tag/v0.0.1
