# Architecture

This document is the contract. If code and this document disagree, one of them
is a bug — fix it in the same pull request.

## Goals

1. **A real emulator.** Nymbra owns its VT parsing and its rendering. It does
   not delegate either to a library.
2. **Zero runtime dependencies.** The shipped binary links only Apple's
   frameworks. Build tooling (`swiftc`, `clang`, `make`) is not a dependency.
3. **A testable core.** Emulation must be verifiable without a window, because
   correctness here is thousands of edge cases, not a handful of features.
4. **A clean dependency direction.** The UI depends on the core. The core knows
   nothing about the UI.

## Non-goals

- Feature parity with iTerm2. We choose a few axes and win those.
- Cross-platform. This is a macOS application and will use macOS APIs directly.
- Plugins or a scripting runtime, until the emulator is correct.

## Modules

| Target | Responsibility | May import |
|---|---|---|
| `CPTY` | `openpty()`, `posix_spawn()`, `TIOCSWINSZ`. C, and imports nothing of ours. | Darwin |
| `NymbraSpawn` | `setsid()`, `TIOCSCTTY`, `dup2`, `execv`: the program that claims a shell's terminal and becomes it. An executable, not a library, exec'd in the child's place by `CPTY`. | Darwin |
| `NymbraCore` | PTY lifecycle, VT parsing, screen model, scrollback, configuration, colour tables, selection. No UI. | Foundation, CPTY |
| `NymbraInput` | Keyboard mapping: a key press to the bytes a terminal sends, and the application's own commands and shortcuts. No UI. | Foundation |
| `Nymbra` | Window, settings window, menu bar, input, rendering. | AppKit, CoreText, Metal, NymbraCore, NymbraInput |
| `NymbraCheck` | The test harness and suites. | NymbraCore, NymbraInput |

### What lives where

The rule is that anything with a right answer belongs in a target that has tests,
and only the part that needs a screen lives in the app.

| Concern | Home | Why there |
|---|---|---|
| Screen model, parser, scrollback | `NymbraCore/Screen.swift`, `Parser.swift` | Thousands of edge cases; must be testable in milliseconds |
| Settings model, loading, validation | `NymbraCore/Configuration.swift` | "A broken settings file still starts" is a property, not a look |
| Colour tables, contrast, 256-colour ramp | `NymbraCore/Palette.swift` | "Is this readable?" is arithmetic, and a screenshot cannot answer it |
| Selection and text extraction | `NymbraCore/Selection.swift` | Copy has an exact expected result |
| Application commands and shortcut parsing | `NymbraInput/Commands.swift`, `Shortcut.swift` | One list read by the menu bar *and* the settings window, so they cannot drift |
| `CGColor` conversion, SGR → colours | `Nymbra/Theme.swift` | The only part that needs a graphics context |
| Font resolution and metrics | `Nymbra/Fonts.swift` | CoreText, and shared by the grid and the preview so they cannot disagree |
| Grid drawing, selection highlight, clipboard | `Nymbra/TermView.swift` | The renderer |
| Windows, settings UI, menu bar | `Nymbra/AppController.swift`, `TerminalWindow.swift`, `SettingsWindow.swift`, `AppMenu.swift` | AppKit, and deliberately thin |
| Claiming a shell's terminal | `NymbraSpawn/main.c`, `NymbraCore/PTY.swift` | It is `ioctl` and `exec`: the one thing `posix_spawn` cannot express, so it is its own program (ADR-0008) |

### The dependency rule

```
Nymbra  ──▶  NymbraCore  ──▶  CPTY
   └────▶  NymbraInput
```

Arrows are compile-time dependencies and point one way. Enforced by
`Scripts/check-architecture.sh`, which fails CI if any UI framework appears in
`Sources/NymbraCore`, `Sources/NymbraInput`, `Sources/CPTY` or
`Sources/NymbraSpawn`. `NymbraSpawn` is an arrow that is not in the diagram
because it is not a compile-time dependency at all: `CPTY` starts it by path at
runtime, and it execs the shell, so it may safely import anything it likes and
imports nothing.

The reason is not purity: it is that the emulator is the hard part and must be
testable in milliseconds, without launching a window or a GPU. `NymbraInput`
exists for the same reason — key mapping is where "arrows and function keys
work" is decided, and that belongs in a table with tests rather than in a
`switch` inside a view that can only be checked by hand.

## Data flow

```
shell  ──bytes──▶  PTY master fd
                        │
                        ▼
                  reader thread            (one per session, owned by us)
                        │  chunks
                        ▼
                  VT parser                (NymbraCore/Parser.swift)
                        │  mutations
                        ▼
                  screen model             (NymbraCore/Screen.swift)
                        │  cells
                        ▼
                  renderer                 (Nymbra/TermView.swift — CoreText now, Metal in M3)
                        ▲
                        │  colours, font, grid metrics
                  settings                 (Configuration ─▶ Palette ─▶ Theme)
```

Each stage has one job. The parser never touches a graphics context; the
renderer never parses escape sequences; the PTY never formats anything. Settings
enter the renderer as data rather than as a global, which is what makes the
settings window's live preview a matter of calling one `apply` method.

### Starting a shell

That flow begins at the shell, and putting a shell on the other end of a terminal
is not one call. `openpty()` produces a master and a slave; three things then
have to become true of the process that will own the slave, and only one of them
can be arranged from the parent:

| What must be true | How it becomes true |
|---|---|
| It is a session of its own | `setsid()`, in the child |
| The slave is its **controlling terminal** | `ioctl(fd, TIOCSCTTY, 0)`, in the child |
| It is that terminal's **foreground process group** | Follows from the claim |

`posix_spawn` can express none of the middle column: its file actions run *before*
its attributes, and there is no attribute for an `ioctl`. So the claiming is a
program, `NymbraSpawn`, which `CPTY` execs with the slave's descriptor inherited
and an argument list that ends in the shell. It claims the terminal, makes it
stdin, stdout and stderr, closes every descriptor above stderr, and execs. After
that the process *is* the shell — same pid, same session, same terminal.

Two details are easy to get wrong and are stated here because both are silent.
The parent closes its own copy of the slave the moment the spawn returns: while
*anyone* holds the slave open, the master never reports end of file, so a stray
copy is a pane that stays on screen for good after its shell has exited. And the
descriptor is inherited rather than reopened by name, because a master with no
slave open reports end of file *immediately* — a reader that starts before the
child has opened the device would take that for the shell having exited
(ADR-0008).

## Invariants

These must hold at all times. Add a test when you touch them.

1. **The screen model is the single source of truth.** The renderer is a pure
   function of the model plus cell metrics.
2. **No allocations on the read path.** Output arrives in large bursts; the
   parser appends into preallocated storage, not fresh arrays per byte.
3. **The parser is total.** Any byte sequence, valid or hostile, must leave the
   model in a well-defined state. It may not crash, hang, or allocate unboundedly.
4. **One session, one reader.** Exactly one thread reads a given PTY master.
5. **The process is never forked.** Shells are started with `openpty()` +
   `posix_spawn()` (ADR-0007), and the one program of ours that runs before a
   shell is `NymbraSpawn`, which claims the terminal (ADR-0008) — and it too is
   `exec`'d by `posix_spawn`, never forked. So no process in Nymbra is a copy of
   another: `fork()` is not called anywhere, no code of ours runs between a spawn
   and its `exec`, and the helper begins with a process image that has never held
   AppKit. This is the strongest available form of the rule that ADR-0002
   introduced, which was "the child may only make async-signal-safe calls" — a
   rule the child has now stopped needing, because there is no forked child. It
   is also what allows a shell to be started at any time, with AppKit and its
   threads already running, which is what tabs, splits and "New Window" all
   required.
6. **The grid is measured, not assumed.** Cell width and height come from
   CoreText metrics for the active font.
7. **An unreadable colour is a bug, not a preference.** A foreground below 4.5:1
   against the background it is drawn on is lifted until it clears the bar
   (`Palette.readable`). `SGR 8` and `SGR 2` are the exceptions — conceal and
   faint exist to remove contrast.
8. **A grid crosses a layer boundary as one value.** The number of rows and the
   number of columns travel together as `GridSize`, never as two bare integers.
   Transposing them is silent: the shell formats its output to a width equal to
   the window's height, and every wide line wraps mid-field (invariant 6 is the
   same instinct for metrics — measure, then keep the measurement intact).

## Threading

| Thread | Owns |
|---|---|
| Main | AppKit, the window, all drawing, the screen model |
| Reader (one per session) | Blocking reads on the PTY master |

The reader hands byte chunks to the main thread. The model is only ever mutated
on the main thread, so it needs no locking. When throughput demands it, parsing
may move to the reader, at which point the model becomes a lock-protected or
actor-isolated boundary — that change must come with a benchmark.

## Where the difficulty lives

The VT parser. ECMA-48 plus the `xterm` control-sequence reference define
several hundred behaviours, and the last 10% of them are 90% of the work.
`NymbraCore/Parser.swift` is a single state machine over the families: ground,
escape, CSI, OSC, DCS, charset and the `SOS`/`PM`/`APC` strings. Every family
shares the entry rules and differs only in how it terminates — the table at the
top of that file is the whole design, and it is the place implementations go
wrong.

Still owed:

1. A larger **conformance corpus** of input → expected screen pairs. Today these
   are assertions in-source rather than fixtures. It may grow; it must not shrink.
2. Fuzzing at scale. The parser must be total (invariant 3), and is currently
   fuzzed with ~10⁵ random bytes per run rather than the 10⁶ the roadmap asks for.

Written from the specifications, not from another emulator's source. See
ADR-0001.

## Testing strategy

| Layer | How |
|---|---|
| Escape-sequence state machine | Unit tests in `NymbraCheck` |
| Keyboard mapping | Unit tests in `NymbraCheck`; the mapping is a UI-free target |
| Viewport and scrollback | Unit tests on `Screen.displayRows` |
| Screen model | Unit tests, including resize and scrollback |
| Parser conformance | Input bytes → expected cells, asserted from `NymbraCheck` |
| Settings model | Unit tests, including hostile config files that must still start |
| Colours and legibility | Unit tests on `Palette`, plus `--theme-test` for CI |
| Selection and copy | Unit tests on `Selection.text(in:scrollOffset:)` |
| Commands and shortcuts | Unit tests on `Command`/`Shortcut`, including duplicates |
| PTY | `--pty-test` smoke test in CI |
| Controlling terminal and job control | `PTYSuite` asks the kernel, headlessly: `tcgetpgrp` for the shell, a job's own process group, whether Ctrl+C ends it and hands the terminal back, and whether a program that never touches its terminal has one |
| Emulation, end to end | `--screen-test` feeds real shell output through the parser in CI |
| Menu bar | `--menu-test` prints the menu and its key equivalents |
| Rendering | Manual + snapshot once Metal lands |

`make check` runs everything that can run without a human.

## Future decisions, already constrained

- **Metal**: the renderer will be replaced behind the same "pure function of
  the model" boundary. No core changes required (ADR-0004).
- **Remote sessions / SSR**: the PTY layer must eventually move out of process
  so a session can outlive the window. Keep PTY concerns behind `NymbraCore`'s
  interface so this is a swap, not a rewrite.
