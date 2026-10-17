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

### Added — M2, settings and configuration

- `Configuration`: the settings model, in the UI-free core. Every field has a
  default and loading is **total** — a missing file is the defaults, a malformed
  one is the defaults plus a warning, and a key from a newer version is ignored
  rather than fatal. See
  [ADR-0006](docs/adr/0006-configuration-as-a-validated-json-file.md).
- Stored at `~/Library/Application Support/Nymbra/config.json`, overridable with
  `$NYMBRA_CONFIG` so tests and CI never touch a real user's settings.
- A **settings window** with tabs for Appearance, Colours, Behaviour, Keyboard
  and Shell, and a **live preview** drawn with the same `Theme` and palette the
  terminal uses. Changes apply to the open terminal as they are made; the file
  write is debounced, so dragging a stepper does not write per pixel.
- `Palette` in the core: three presets (dark, light, high contrast), per-colour
  overrides, WCAG contrast arithmetic, and the xterm 256-colour table. Only the
  `CGColor` conversion lives in the app, in `Theme`.
- `Selection`: click, double-click, triple-click and drag, with text extraction
  in the core. Copy (Cmd+C) and paste (Cmd+V, with bracketed-paste guards).
- `Command` and `Shortcut` in `NymbraInput`: one list of application commands
  read by **both** the menu bar and the settings window, so a shortcut the app
  advertises cannot drift from one it honours. Parsing is strict, and a duplicate
  is refused at the moment it is typed rather than silently shadowing.
- `--theme-test` and `--menu-test`, which print the palettes and the menu bar as
  text for the same reason `--screen-test` exists: CI cannot look at a window.
- The settings window's Reset shows **what will change**, as a diff, rather than
  silently wiping.
- 687 checks, up from 246: palette, selection, shortcut, PTY and grid suites,
  plus the existing configuration suite and its sixteen hostile files.

### Fixed — `ls` appeared to hide filenames

- `ls -G` and `ls -l` print directories in ANSI colour 4. The first palette used
  the traditional xterm blue, RGB(0,0,238), which is **2:1** against the dark
  background — so directories read as missing text rather than as blue text. Two
  changes, because there are two halves to the problem:
  - every colour in every preset now clears **4.5:1** (WCAG AA) against its own
    background, asserted in `PaletteSuite` and by `--theme-test` in CI;
  - `Palette.readable(_:on:)` lifts any foreground a *program* chooses below the
    bar, which is what protects `LS_COLORS`, `git` and true-colour output. The
    nudge is the smallest one that clears the bar, tries both directions, and
    leaves a legible colour exactly as it was. `SGR 8` (conceal) and `SGR 2`
    (faint) opt out, because hiding and dimming are what those codes are for.
- Recorded as invariant 7 in `docs/ARCHITECTURE.md`.

### Fixed — `ll` printed every entry on two rows

The symptom was a long listing sliced in half: each entry spread over two rows
with the year split from the month — and only when the window was **not full
screen**. The renderer was innocent, and so was the palette fixed above.

`TermView` reported its grid to the shell as `(cols, rows)`; `TerminalWindow`
read it back as `(rows, cols)`. Every window resize therefore told the shell a
width equal to the window's **height**. Nothing about that is visible in the app
itself: we draw a 125-column grid while the shell — `eza` here, but it would be
`ls -l` or `git log` — formats its output for 39 and hands back lines that wrap
mid-field. It looked correct in full screen only by accident, because the row
count there (about 61) had grown past the width the listing needed (about 60).

- Rows and columns now cross the layer boundary as a single value, `GridSize`,
  in the core: `Terminal(size:)`, `Terminal.resize(_:)` and `TermView.onResize`.
  The transposition is not merely fixed, it is unrepresentable — recorded as
  invariant 8 in `docs/ARCHITECTURE.md`.
- `--resize-test` asserts the property a transposed grid destroys: in a window
  wider than it is tall there must be more columns than rows. It runs in
  `make check`, because no window is available to CI.
- `GridSuite` pins the arithmetic, the degenerate windows (smaller than their own
  padding, a zero-sized cell) and the model's field order.

### Fixed — CI was red, and had been since M1

`--pty-test` failed on the runner and passed locally every time, so the answer
was only ever going to come from CI's own output. It was not the shell, the
runner, or the test. The diagnosis is now printed by the failing step, which is
what made it visible at last:

```
objc[4452]: +[NSPathStore2 initialize] may have been in progress in another
thread when fork() was called. We cannot safely call it or ignore it in the
fork() child process. Crashing instead.
```

- **The `forkpty` child was using Foundation.** `spawnShell` computed a basename
  with `(path as NSString).lastPathComponent`, which bridges a Swift `String`
  into the Objective-C runtime. The runtime is shared with the parent, and a
  child that touches it while another thread is initialising a class is killed
  by the runtime itself. The child died before `exec`, and because a PTY's line
  discipline echoes what is typed into it, the terminal still showed the command
  — so the failure read as "a shell that ignored `TERM`".
  - The path, the argument vector, the environment and even the bytes of the
    message printed when `execve` fails are now built in the **parent**; the
    child calls `execve`, `write` and `_exit` and nothing else. `setenv` is gone
    from the child as well: it is not async-signal-safe. See the amendment to
    [ADR-0002](docs/adr/0002-forkpty-before-appkit.md) and invariant 5.
  - `PTYSuite` now proves a shell is really on the other end: it sends
    `echo NYMBRA_$((6*7))` and requires `NYMBRA_42` — arithmetic the echo of the
    command line cannot perform — and asserts the output contains no `objc[`.
- `resolveShell()`: an **empty** `$SHELL` is treated as unset rather than handed
  to `execve`. This was a second, independent fault on the same path: a runner
  whose `SHELL` is set but empty fails the instant the child starts.
- `Scripts/emulation-checks.sh`: the `CUP` check positioned the cursor at row 5
  and expected that row to be empty except for its `X`. Locally the prompt is two
  rows and row 5 is blank; on the runner the shell prints more lines first, so
  row 5 already had text. The check now clears the screen before positioning the
  cursor, so it no longer depends on how long anybody's prompt is.
- `--pty-test` said nothing about what it saw, and could pass on an empty
  capture. It now names the resolved shell and the number of bytes read on
  **stderr**, exits non-zero when the shell produced nothing at all, and the CI
  step prints the capture when a check fails instead of just `exit 1`.
- `ptyRead` retries `EINTR` instead of reporting it as end of output. A signal
  arriving mid-read truncated a session at a random point, which only ever shows
  up under load.

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

### Changed — the app is wired through a controller
- `AppController`, `TerminalWindow`, `AppMenu` and `SettingsWindow` replace the
  inline wiring in `main.swift`. The menu bar is built from the same command list
  the settings window edits, and settings are applied to every open window and
  then saved.
- Cursor style and blink come from the configuration, with DECSCUSR winning once
  a program has asked for a shape of its own.
- ANSI colours, interface colours and the 256-colour ramp come from the palette
  rather than a hardcoded table.

### Changed — roadmap order
- Settings are now **M2, ahead of the Metal renderer (M3)**, because live preview
  requires a configuration-driven renderer; building the renderer first would
  mean writing it twice. Milestones after M1 are renumbered accordingly, and the
  README, ARCHITECTURE and ADR-0004 now agree with the ROADMAP.

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
