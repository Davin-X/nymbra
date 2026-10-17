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
| `CPTY` | `forkpty()`, `TIOCSWINSZ`. The only C in the project. | Darwin |
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

### The dependency rule

```
Nymbra  ──▶  NymbraCore  ──▶  CPTY
   └────▶  NymbraInput
```

Arrows are compile-time dependencies and point one way. Enforced by
`Scripts/check-architecture.sh`, which fails CI if any UI framework appears in
`Sources/NymbraCore`, `Sources/NymbraInput` or `Sources/CPTY`.

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

## Invariants

These must hold at all times. Add a test when you touch them.

1. **The screen model is the single source of truth.** The renderer is a pure
   function of the model plus cell metrics.
2. **No allocations on the read path.** Output arrives in large bursts; the
   parser appends into preallocated storage, not fresh arrays per byte.
3. **The parser is total.** Any byte sequence, valid or hostile, must leave the
   model in a well-defined state. It may not crash, hang, or allocate unboundedly.
4. **One session, one reader.** Exactly one thread reads a given PTY master.
5. **`forkpty()` runs before AppKit starts.** See ADR-0002 — forking a process
   with live threads and Mach ports is undefined behaviour on macOS.
6. **The grid is measured, not assumed.** Cell width and height come from
   CoreText metrics for the active font.
7. **An unreadable colour is a bug, not a preference.** A foreground below 4.5:1
   against the background it is drawn on is lifted until it clears the bar
   (`Palette.readable`). `SGR 8` and `SGR 2` are the exceptions — conceal and
   faint exist to remove contrast.

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
