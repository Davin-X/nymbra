# Nymbra

A native terminal emulator for macOS, written from scratch.

[![CI](https://github.com/Davin-X/nymbra/actions/workflows/ci.yml/badge.svg)](https://github.com/Davin-X/nymbra/actions/workflows/ci.yml)
[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)
[![Platform: macOS 11+](https://img.shields.io/badge/platform-macOS%2011%2B-lightgrey.svg)](#requirements)
[![Dependencies: none](https://img.shields.io/badge/runtime%20dependencies-none-brightgreen.svg)](docs/ARCHITECTURE.md)

Nymbra is a terminal emulator built directly on AppKit, CoreText and a POSIX
pseudo-terminal. It has **no third-party runtime dependencies** — no embedded
browser engine, no JavaScript terminal library, and no wrapper around another
emulator.

```
$ otool -L .build/release/Nymbra
    AppKit, CoreText, CoreGraphics, Foundation, libSystem (Apple SDK only)
```

> **Status: pre-alpha.** The emulator core works: Nymbra runs your login shell
> and emulates cursor movement, colour, erasing, line and character editing,
> scroll regions, the alternate screen, wrapping and resize. Full-screen
> programs are exercised in CI by feeding real terminal output through the
> parser. Settings are real, too: a JSON file, a settings window with a live
> preview, three palettes, and select-and-copy.
>
> It is not yet a daily driver. Missing: tabs and splits, search, mouse reporting
> (the modes are tracked, but no bytes are sent yet), text reflow on resize, and
> the Metal renderer that will replace CoreText drawing.
>
> See [docs/ROADMAP.md](docs/ROADMAP.md) for what is planned and
> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it is built.

## Why another terminal

The terminal is the one tool a developer never closes, yet most macOS terminals
are either dated, heavy, or an embedded web view. Nymbra exists to be **native,
quiet, and to remember what you were doing** — rather than to out-feature
[iTerm2](https://iterm2.com), which has fifteen years of head start.

The differentiators we intend to own are listed in
[docs/ROADMAP.md](docs/ROADMAP.md#differentiators).

## Requirements

| | |
|---|---|
| macOS | 11 or later |
| Toolchain | Xcode **Command Line Tools** (`xcode-select --install`) |
| Swift | 6.0 or later |
| Xcode | Not required |
| Runtime dependencies | None |

Full Xcode is deliberately unnecessary: Metal shaders are compiled at runtime
rather than offline.

## Build and run

```sh
git clone https://github.com/Davin-X/nymbra.git
cd nymbra
make build
.build/release/Nymbra
```

There are no binary releases yet.

## Settings

Press **Cmd+,** (or use the application menu) to open the settings window. Changes
apply to the open terminal as you make them — the preview is a real terminal
drawing with the same code and the same colours as the window behind it, not a
mock-up. Reset shows what will change before it changes anything.

Settings live in one hand-editable JSON file:

```
~/Library/Application Support/Nymbra/config.json
```

Set `$NYMBRA_CONFIG` to point somewhere else — that is how the tests and CI run
without touching your settings. Loading is deliberately total: a missing file is
the defaults, a malformed one is the defaults plus a warning, and an unknown key
from a future version is ignored. A terminal must never refuse to start because
of its own settings file.

## Development

| Command | Purpose |
|---|---|
| `make build` | Release build |
| `make test` | Run the test harness |
| `make pty-test` | Headless proof that a login shell runs on a PTY |
| `make screen-test` | Feed real output through the parser and dump the screen |
| `make check` | Everything CI runs |
| `make clean` | Remove build output |

The binary also prints things a test runner cannot look at, so that they can be
asserted in text rather than by eye:

| Flag | Prints |
|---|---|
| `--screen-test "<cmd>"` | The screen after running `<cmd>` in a real shell |
| `--screen-debug "<cmd>"` | The same screen with blanks shown as `·` |
| `--theme-test` | Every preset, and the contrast of every colour in it |
| `--menu-test` | The menu bar and its key equivalents |
| `--settings-test` | The settings window's tabs and what each control loaded |

`make check` is the gate: it must pass before any change is considered done.
See [CONTRIBUTING.md](CONTRIBUTING.md).

## Architecture

```
                ┌──────────────┐
                │   Nymbra     │  windows, settings window, CoreText renderer
                └──────┬───────┘
                       │ depends on
                ┌──────▼───────┐
                │ NymbraCore   │  PTY, VT parser, screen model, config, palette
                └──────┬───────┘
                       │ depends on
                ┌──────▼───────┐
                │    CPTY      │  forkpty() / TIOCSWINSZ — 25 lines of C
                └──────────────┘
```

The dependency arrow points **one way only**. `NymbraCore` and `CPTY` may not
import a UI framework, and CI enforces this with
[`Scripts/check-architecture.sh`](Scripts/check-architecture.sh). This is what
keeps the emulator testable without a window.

Full detail, including the threading model and the invariants that must hold:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Roadmap

| Milestone | Scope | Status |
|---|---|---|
| M0 | PTY, window, CoreText grid, tests, CI | ✅ complete |
| M1 | VT emulation, keyboard, scrollback viewport | ✅ core complete |
| M2 | Settings, configuration, palettes, select and copy | ✅ complete |
| M1.x | Tabs and splits | ⏳ next |
| M3 | Metal renderer, search, reflow, mouse | planned |
| M4 | Shell integration (OSC 133) and notifications | planned |
| M5 | Sessions: a PTY host that outlives the window | planned |
| M6 | Signed, notarized release and updater | planned |

Full plan, feature catalogue and acceptance criteria:
[docs/ROADMAP.md](docs/ROADMAP.md).

## Contributing

Issues and pull requests are welcome. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) first — in particular the architecture rule
and the requirement that tests pass.

## Licence

[MIT](LICENSE).

## Acknowledgements

Built on Apple's own frameworks — AppKit, CoreText, CoreGraphics and Metal. The
default typeface is the system-provided Menlo; no font is redistributed.
