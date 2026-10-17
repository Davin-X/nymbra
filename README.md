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

> **Status: pre-alpha.** Nymbra is scaffolding, not a daily driver. It opens a
> window, runs your login shell, and draws output on a CoreText grid.
> It has no cursor, no colour, no alternate screen, and no scrollback across
> resizes — running `vim` or `htop` will produce nonsense.
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

## Development

| Command | Purpose |
|---|---|
| `make build` | Release build |
| `make test` | Run the test harness |
| `make pty-test` | Headless proof that a login shell runs on a PTY |
| `make check` | Everything CI runs |
| `make clean` | Remove build output |

`make check` is the gate: it must pass before any change is considered done.
See [CONTRIBUTING.md](CONTRIBUTING.md).

## Architecture

```
                ┌──────────────┐
                │   Nymbra     │  AppKit window, CoreText renderer
                └──────┬───────┘
                       │ depends on
                ┌──────▼───────┐
                │ NymbraCore   │  PTY, screen buffer, (planned) VT parser
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
| M1 | VT emulation: cursor, SGR colour, alt screen | ⏳ next |
| M2 | Metal renderer with a glyph atlas | planned |
| M3 | Shell integration (OSC 133) and notifications | planned |
| M4 | Session persistence | planned |
| M5 | Signed, notarized release and updater | planned |

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
