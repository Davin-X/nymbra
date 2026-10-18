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
> preview, eight palettes, and select-and-copy. So are windows: **⌘N** opens
> another with its own shell, and closing one is not a dead end.
>
> It is not yet a daily driver. Missing: search, and the Metal renderer
> that will replace CoreText drawing.
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

Or build a real application bundle, which is what you want if you are going to
keep it in the Dock or hand it to somebody:

```sh
make app        # build/Nymbra.app, icon and all
make launch     # build it and open it from Finder
make install    # copy it to /Applications (or ~/Applications)
make dist       # build/Nymbra.zip, ready to send
```

The icon is drawn by `Scripts/make-icon.swift` at build time rather than stored
as a binary, so it is reviewable and reproducible — and derived from the same
colours the terminal itself uses.

The bundle is **unsigned**. It runs anywhere it was built; it will not survive a
download from the internet without Gatekeeper objecting, which is what code
signing and notarisation in M6 are for.

## Settings

Press **Cmd+,** (or use the application menu) to open the settings window. Changes
apply to the open terminal as you make them — the preview is a real terminal
drawing with the same code and the same colours as the window behind it, not a
mock-up. Reset shows what will change before it changes anything.

Settings live in one hand-editable JSON file:

```
~/Library/Application Support/Nymbra/config.json
```

Eight palettes ship with it: **Dark**, **Ember** (warm dark), **Fern** (green
dark), **Violet** (purple dark), **Light**, **Paper** (warm light), **Dawn**
(soft light) and **High contrast**. They are not recolours of one table — each
has its own hues and its own saturation — but they share one rule, and it is a
tested one rather than a preference: **every colour clears WCAG AA (4.5:1)
against the background it is drawn on**. The traditional xterm palette puts blue
at `#0000EE`, which is 2:1 on a dark page, and `ls` colours directories exactly
that blue. Any colour a *program* chooses that falls below the bar is lifted
until it clears it, unless it asked for conceal or faint.

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
| `make app` | Build `Nymbra.app`, icon included |
| `make install` | Copy the bundle to `/Applications` (or `~/Applications`) |
| `make dist` | Zip the bundle for somebody else |
| `make pty-test` | Headless proof that a login shell runs on a PTY |
| `make screen-test` | Feed real output through the parser and dump the screen |
| `make resize-test` | Proof that the view and the shell agree on the grid |
| `make window-test` | Close a window and get a working shell back |
| `make tabs-test` | A tab strip, tabs made, switched and closed independently |
| `make mouse-test` | Mouse reporting bytes, asserted headlessly |
| `make shell-integration-test` | A real zsh, reporting what it is doing |
| `make notify-test` | A long command in a background tab, announced |
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
| `--resize-test` | The grid the view reports against the grid the shell is told |

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
                │    CPTY      │  openpty() + posix_spawn() / TIOCSWINSZ
                └──────┬───────┘
                       │ execs, with the terminal inherited
                ┌──────▼───────┐
                │ NymbraSpawn  │  setsid() + TIOCSCTTY + execv: claims the shell's terminal
                └──────────────┘
```

The dependency arrow points **one way only**. `NymbraCore` and `CPTY` may not
import a UI framework, and CI enforces this with
[`Scripts/check-architecture.sh`](Scripts/check-architecture.sh). This is what
keeps the emulator testable without a window.

`NymbraSpawn` is the one arrow drawn for a *runtime* dependency: it is not a
library but a small program that `CPTY` starts and that execs the shell in turn,
so it depends on nothing and is the reason Ctrl+C works. See
[ADR-0008](docs/adr/0008-the-helper-owns-the-terminal.md).

Full detail, including the threading model and the invariants that must hold:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Roadmap

| Milestone | Scope | Status |
|---|---|---|
| M0 | PTY, window, CoreText grid, tests, CI | ✅ complete |
| M1 | VT emulation, keyboard, scrollback viewport | ✅ core complete |
| M2 | Settings, configuration, palettes, select and copy | ✅ complete |
| M1.x | Tabs and splits | ✅ done |
| M3 | Metal renderer, search, reflow, mouse | 🔨 search, reflow and mouse done; Metal renderer next |
| M4 | Shell integration (OSC 133) and notifications | 🔨 zsh marks behind an off-by-default setting, and a long command that finishes out of sight is announced; click-to-focus, `bash`/`fish` and the timeline next |
| M5 | Sessions: a PTY host that outlives the window | planned |
| M6 | Signed, notarized release and updater | ⏳ bundle and icon done; signing remains |

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
