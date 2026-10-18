# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — the shell can now say what it is doing

The parser understands `OSC 133`, the sequence a shell writes to report its own
progress: `A` when a prompt goes up, `B` where the command line begins, `C` just
before the command runs, and `D` when it has finished, carrying the exit status.
The marks arrive as a `ShellMark` through `Parser.onShellMark` and
`Terminal.onShellMark`, and not one of them is ever drawn.

- A finish with no status is reported as *no status*, not as success: `OSC 133;D`
  and `OSC 133;D;0` say different things, and the parser keeps them apart rather
  than picking a default that reads as "it worked".
- The parser treats an unknown mark, and a code that merely starts with `133`
  (`1337`), exactly as it treated every other OSC it does not implement: ignored,
  and never guessed at.
- Nothing is built on the marks yet, and nothing can be: a mark is only worth
  what the shell that emits it is worth, and no shell emits these by itself. The
  snippets that teach `zsh`/`bash`/`fish` to write them come next, and the badge,
  the notification and the timeline that M4 promises are all downstream of that.

### Fixed — `make check` could never pass

`make check` ran `swiftlint lint --strict` as its first step. But the CI job that
ran SwiftLint was removed a while ago and `.swiftlint.yml` was deleted with it;
the step was left behind. It fails for two different reasons, neither of them a
statement about this code: with no config, a strict lint fails on a codebase that
never adopted the default rules, and under Command Line Tools alone `swiftlint`
aborts before linting anything at all
(`Loading sourcekitdInProc.framework … failed`). So `make check` was red on a
machine where nothing was wrong — including the CLT-only machines the README
promises Nymbra builds on, and the pull-request template asks everyone to tick
"`make check` passes locally".

- `lint` is no longer a prerequisite of `check`. It stays as a convenience that
  skips itself, with a word, when `swiftlint` is not installed.
- `check` now runs the architecture guard that CI runs first — which `make help`
  already claimed it did ("everything CI runs") and it did not.

### Added — the unread tab badge

A tab that prints while it is not the one in front now marks itself: a dot on its
strip label, cleared by looking at the tab. Output you are watching is not news,
so the tab in front is never marked — which is also why the mark is kept by the
window rather than by the tab. "Unread" is a claim about the person's attention,
and only the window knows where that is.

- The mark is drawn in the tab's own label, which is the one piece of a tab a
  plain `NSTabView` lets us paint, so `make tabs-test` reads it off the strip
  rather than off a flag beside it: `… unread=1 …`. A dot that was set but never
  painted would fail that check, which is the point of asking the label.
- This is the *output* half of the badge. The half the roadmap asks for in M4 — a
  dot when a background command **finishes**, with its exit status — needs the
  `OSC 133` shell integration that is not parsed yet, and stays in M4.

### Added — tabs and split panes

A window can hold several shells now. **Tabs** each own their panes, with a
visible tab strip and a title that follows the focused shell (`⌘⇧T` new,
`⌘⇧W` close, `⌘⇧[` / `⌘⇧]` to move between them). **Splits** put a second shell
beside or below the current one (`⌘D`, `⌘⇧D`), closed with `⌘W`. Focus follows a
click, and `⌘[` / `⌘]` move it between panes without the mouse.

- Every pane owns an independent shell and an independent model, with no shared
  mutable state between them — which is what makes four different programs in
  four panes behave like four terminals rather than four views of one.
  `make split-test` starts four panes, runs a command in each, and checks that
  closing panes leaves the others undisturbed: `panes=4 … jobControl=1 …
  closed=3 sameShells=1`.
- The tab commands are asserted without a window by `make tabs-test`:
  `strip=1 plus=1 created=1 ownShells=1 independent=1 switched=1 title=1
  unread=1 closed=2 sameShells=1 lastTabClosesWindow=1`.
- The per-tab **unread badge** landed after this, in the same release — see the
  entry at the top of this section. Its *finished-command* form needs `OSC 133`
  and stays in M4.

### Added — search in scrollback

`⌘F` opens a find overlay. Matches are found in scrollback and on the live
screen, highlighted where they sit, and stepped through with next/previous
(`⌘G` / `⌘⇧G`). A match in history scrolls the viewport to it; typing returns to
the live screen, as it does everywhere else.

### Added — text reflow on resize

Resizing used to preserve content without rewrapping it: a paragraph kept the row
breaks it was written with, so a narrow pane showed a ragged column and a wide
one a short one. The live screen now rejoins soft-wrapped rows and recuts them to
the new width, so text reflows the way a document does; hard line breaks are
never joined. Scrollback entries are one hard line each, so they are padded or
cut to the new width rather than joined. The alternate screen keeps the old
preserve-and-trim behaviour, because the application running there reacts to
`SIGWINCH` itself.

### Added — mouse reporting

Programs that ask for mouse events now receive them. Modes `1000` (clicks),
`1002` (drag) and `1003` (any motion) are tracked, in both the X10 and SGR
encodings, with modifier bits carried through. While mouse reporting is on, the
wheel is reported as buttons 4 and 5; with it off, the wheel scrolls scrollback
as before.

### Fixed — Ctrl+C, Ctrl+Z and job control did nothing

The most useful thing a terminal does after running a command is stop it. In
everything shipped so far it could not: the shell had **no controlling terminal**,
so the kernel had no foreground process group to deliver a signal to.
`tcgetpgrp(master)` answered `0` for the life of every shell.

Nothing on screen said so, which is why it took a test that asks the kernel
rather than a person watching a prompt. The prompt appeared, keystrokes echoed,
commands ran, output rendered — all of that is the line discipline, which works
without a controlling terminal. What was missing was everything that needs a
*foreground process group*: Ctrl+C, Ctrl+Z, hangup, `^Z`-then-`fg`, and job
control, which zsh turns off silently when it cannot find its terminal.

- **The cause was an ordering mistake in [ADR-0007](docs/adr/0007-posix-spawn-instead-of-forkpty.md).**
  That decision opened the slave with a `posix_spawn` *file action*, on the
  reasoning that the first terminal a session leader opens becomes its
  controlling terminal. POSIX runs file actions **before** spawn attributes, so
  the open happened while the child was still in the parent's session — where it
  cannot claim anything — and `POSIX_SPAWN_SETSID` created the session
  afterwards. The claim was described as the fix for exactly this symptom, and
  was the cause of it.
- **The claim is now a program that owns the terminal.** `openpty()`, then a
  helper — [ADR-0008](docs/adr/0008-the-helper-owns-the-terminal.md) — which
  `posix_spawn` execs in place of the shell: `setsid()`, `ioctl(fd, TIOCSCTTY, 0)`
  on an **inherited** descriptor, `dup2` onto 0/1/2, close every descriptor above
  stderr, `execv`. After that the process *is* the shell — same pid, same session,
  same terminal — and Ctrl+C has somewhere to go.
- The descriptor is inherited rather than reopened by name, and that is not
  fastidiousness: a master with **no slave open reports end of file immediately**,
  and a reader that starts before the child has opened the device would take that
  for the shell having exited. Inheriting it means the child holds the terminal
  from the moment of the spawn, so the handover cannot be observed. The parent
  closes its own copy as soon as the spawn returns, because while *anyone* holds
  the slave open the master never reports end of file at all — a stray copy is a
  pane that outlives its shell.
- `posix_spawn` and "no `fork()`" both stand (ADR-0007's actual decision is
  untouched): the helper is exec'd, never forked, so it begins with a process
  image that has never held AppKit and invariant 5 is unaffected.
- `Scripts/make-app.sh` copies `NymbraSpawn` into `Contents/MacOS/`, next to the
  binary that looks for it, and `Scripts/check-architecture.sh` covers the new
  target. A missing helper is reported by name and path rather than as a pane
  that never appears.
- **The suite had to learn to be a terminal, and that was the second bug.** The
  buffer between a terminal and its reader is about **1024 bytes**: a program that
  has filled it blocks in `write`, including a shell halfway through drawing its
  prompt, which then never reads the command the test is about to send. The tests
  were stopping between assertions, so they stalled the shells they were asking
  about — one hung in an unkillable `exit`. `PTYSuite` now drains while it waits,
  every blocked wait has a deadline, and the eight-shell check asks for a marker
  its own echoed command cannot supply.
- **New witnesses, because the old ones could not fail.** `/bin/sh` is bash, and
  bash reacquires a controlling terminal for itself, so the earlier assertions
  passed while no shell the application started had one. The suite now asks
  `/bin/sleep` — a program that never touches its terminal — whether it has one,
  asks zsh whether a job gets its own process group and whether Ctrl+C hands the
  terminal back, and asks the shell whether it can see the master of its own
  terminal by number.

### Fixed — closing the window was a dead end

Clicking the red button ended the shell and left Nymbra running with no window,
no way to make another one, and no response to a Dock click. The only route back
to a terminal was to quit and start again. There was no `New Window` item either,
and the reason was structural rather than an oversight: the shell was started with
`forkpty()`, which forks the application, and that is not safe once AppKit has
started — so the one window had to be spawned before the application existed
(ADR-0002), and a second shell had nowhere to come from.

- Shells are now started with `openpty()` + `posix_spawn()`, so a shell can be
  started at any time. ADR-0002 is superseded by
  [ADR-0007](docs/adr/0007-posix-spawn-instead-of-forkpty.md), and invariant 5 is
  stronger than it was: `fork()` is not called anywhere in Nymbra and no code of
  ours runs between the spawn and the `exec`, so the entire class of post-fork
  hazards is unrepresentable rather than merely avoided.
- `File ▸ New Window` (**⌘N**), a rebindable `Command` like every other shortcut,
  so the settings window shows it and refuses a duplicate.
- `applicationShouldHandleReopen` brings a window back — the one still open, or a
  new one — and closing the last window leaves Nymbra running, as a terminal
  should, rather than leaving it running by accident with no way to a shell.
- A closed window is pruned only when the application next needs a window, never
  from inside `windowWillClose`, where releasing the last reference would
  deallocate a window in the middle of closing it.
- If a shell cannot be started at all — a bad `shell.path`, a shell without the
  execute bit — the failure is now reported by the parent, in an alert and on
  stderr, instead of being written onto a terminal that no longer has a child to
  write it.

### Fixed — a new shell started in `/`, not in `~`

A shell inherits the working directory of the process that starts it, and a
process opened from the Finder or the Dock starts in `/`. A shell in `/` cannot
create a file, so the first `mkdir` or `git clone` failed. The shell is now given
a working directory explicitly (`posix_spawn_file_actions_addchdir_np`), without
`chdir()`ing the application out from under its own threads, and `PWD` is set to
match, because shells trust it for `cd -` and for their prompt. Home is the
default — inheritance from a GUI process is worth nothing, and `~` is what the
platform's own terminals choose — and `spawnShell(workingDirectory:)` sets it for
callers that want otherwise.

### Added — proofs for the things that fail silently

Every failure above is quiet: a shell without a controlling terminal still prints
a prompt; a window that cannot reopen still looks like a running application; a
shell in `/` still runs commands. So each one is now asked directly.

- `--window-test` (`make window-test`, a CI step) closes a window, reopens it, and
  requires the new shell to *evaluate* a command — `$((6*7))` only exists as 42 if
  it ran. Nothing is ever shown.
- `PTYSuite` asks the kernel about the terminal the shell was given: that the shell
  is its foreground process group, that a background job gets its own group, that
  **Ctrl+C ends that job** and hands the terminal back, that `SIGPIPE` is at its
  default rather than inherited as ignored, and that `/bin/pwd` prints the
  directory the shell was told to use.
- `PTYSuite` also starts eight shells while four other threads allocate and
  initialise Foundation types — the situation the old rule existed to avoid, and
  the one a forked child could not survive.
- `--pty-test` now prints `tty` and `/bin/pwd` alongside `TERM`, so a CI log shows
  the terminal the shell got and where it started.

### Added — five more colour presets, and a rule that produced them

Three presets was a demo of the colour system rather than a choice. There are now
eight, each with its own hues and saturation rather than the same table with a
different background:

| | | |
|---|---|---|
| **Ember** | warm dark | a lamp-lit room, hues pulled toward orange, so green reads olive |
| **Fern** | green dark | for code that is mostly trees; saturated greens and yellows |
| **Violet** | purple dark | the dark preset with its blues pushed toward violet |
| **Paper** | warm light | a page rather than a screen, at noon |
| **Dawn** | soft light | warm off-white, easier than pure white in a bright room |

They were computed rather than eyeballed. `readable` guarantees a floor; a preset
that has to *use* it is a preset that lies about itself in the settings swatches.
So each colour was solved for the dimmest value that clears 4.5:1 on its own
background, giving up saturation only when a saturated hue could not reach the
bar at any brightness — which is exactly what happens to a saturated blue on a
dark page, and is why the fallback exists. Foregrounds land at 14–16:1 and the
worst ANSI colour in any preset is 4.62:1.

- `PaletteSuite` now iterates `Preset.allCases`, so a preset added later is
  covered by the readability, 16-colour and override assertions automatically
  rather than needing to be added to a list.
- `Scripts/emulation-checks.sh` counts the presets in `--theme-test`'s own output
  instead of expecting three, and asserts that no preset ships a blue that has to
  be rescued at drawing time — generalising what used to be a dark-only check.
- `--settings-test` prints the preset popup's titles, so the names the user
  actually sees are assertable without a window.
- All five are original: own names, own values, nothing taken from another
  terminal's theme.

### Added — a real application bundle, and an icon

Nymbra could only be run as a bare executable, which meant a generic icon in the
Dock, nothing to drag to `/Applications`, and nothing to hand to another person.

- `Scripts/make-app.sh` assembles `build/Nymbra.app`: the release binary, an
  `Info.plist` (identifier, version, minimum macOS, category, `NSPrincipalClass`),
  a `PkgInfo`, and the icon. It lints the plist, because a malformed one makes a
  bundle silently unlaunchable.
- `Scripts/make-icon.swift` **draws** the icon with CoreGraphics instead of
  storing a binary: a rounded square in the terminal's own background colour,
  with a prompt chevron and a block cursor. Every size is rendered from one
  drawing, the mark grows as the canvas shrinks so 16px still reads, and
  `iconutil` compiles the set. Nothing is committed as an opaque artifact.
- `make app`, `make launch`, `make install` (to `/Applications`, falling back to
  `~/Applications`) and `make dist` (a zip). The build number is the commit
  count, so there is no second file to keep in step with the version.
- Unsigned by design at this stage: an unsigned bundle runs where it was built,
  and code signing plus notarisation stay in M6.

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
- `Palette` in the core: three presets (dark, light, high contrast) at first,
  eight now, plus per-colour
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
- 968 checks, up from 246: palette, selection, shortcut, PTY and grid suites,
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
