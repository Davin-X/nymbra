# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — M1, VT emulation
- `Screen`: the screen model — cursor (position, visibility, shape, deferred
  wrap), pen, scrolling region, tab stops, scrollback, alternate screen, and
  resize that preserves content.
- `Parser`: a byte-level state machine covering the ground, escape, CSI, OSC,
  DCS, charset and SOS/PM/APC families, with ECMA-48 parameters including colon
  sub-parameters. Total under fuzz.
- `Attributes` and `Cell`: SGR state (16-, 256- and 24-bit colour; underline
  styles; bold, italic, reverse, conceal, strike) and double-width handling.
- `Terminal`: PTY, parser and screen wired together, reader on its own thread
  and the model confined to the delivery queue.
- Colour rendering from the xterm 256-colour palette, a block/underline/bar
  cursor, and bracketed paste on Cmd+V.
- `--screen-test`: feeds real shell output through the parser and prints the
  resulting screen, so CI can assert emulation without a window.
- 169 checks across a screen suite and a parser suite.

### Added — M2, configuration (first step)
- `Configuration`: the settings model, in the UI-free core. Every field has a
  default and loading is **total** — a missing file is the defaults, a malformed
  one is the defaults plus a warning, and a key from a newer version is ignored
  rather than fatal. See
  [ADR-0006](docs/adr/0006-configuration-as-a-validated-json-file.md).
- Two settings are live already: font family and size, and the shell path. A
  font family that does not resolve falls back to Menlo rather than to a
  substituted non-monospaced font, which would break the grid.
- Stored at `~/Library/Application Support/Nymbra/config.json`, overridable with
  `$NYMBRA_CONFIG` so tests and CI never touch a real user's settings.
- 307 checks, up from 246: a configuration suite, including sixteen hostile files
  that must each leave the app able to start.

### Changed — roadmap order
- Settings are now **M2, ahead of the Metal renderer (M3)**, because live preview
  requires a configuration-driven renderer; building the renderer first would
  mean writing it twice. Milestones after M1 are renumbered accordingly, and the
  README, ARCHITECTURE and ADR-0004 now agree with the ROADMAP.

### Added — input and viewport
- `NymbraInput`: the keyboard mapping as a UI-free target, so "arrows and
  function keys work" is asserted without a window. Covers F1–F20 in both the
  SS3 and `CSI n ~` forms, xterm's modified-key encoding (Ctrl/Shift/Alt with
  arrows and function keys), DECCKM, meta via Option, control combinations, and
  Shift-Tab.
- Viewport scrolling: the wheel or trackpad moves through scrollback.
  `Screen.displayRows(scrollOffset:)` keeps history and live output on a single
  drawing path, and typing returns to the live screen.
- 246 checks, up from 169: a keyboard suite and a viewport suite.

### Changed
- The application now spawns the shell **before** AppKit is initialised, which
  is what ADR-0002 always required. The PTY opens at 80×24 and is corrected with
  `TIOCSWINSZ` once the window's grid size is known.

### Removed
- `TermBuffer`, the M0 scaffolding, replaced by `Screen` and `Parser`.

### Fixed
- OSC sequences are terminated by `BEL` or `ST` (`ESC \`) only. Previously the
  sequence ended at the first byte in `0x40...0x7E`, so an OSC payload
  containing a letter leaked into rendered output.
- `CursorStyle` no longer derives from `rawValue`: DECSCUSR 0 and 1 both mean a
  blinking block and 6 is a steady bar, which a raw-value enum cannot express.
- Turning DECAWM off no longer sets the pending-wrap flag, so the last column is
  overwritten rather than wrapped onto a new line.

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
