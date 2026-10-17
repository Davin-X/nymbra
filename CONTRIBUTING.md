# Contributing to Nymbra

Thanks for taking a look. This document is short on purpose — the rules that
matter are the architecture rule and "tests pass".

## Before you start

Read, in this order:

1. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — the contract, especially the
   dependency rule and the invariants.
2. [`docs/ROADMAP.md`](docs/ROADMAP.md) — what is in scope. If your idea is not
   there, open an issue first; scope creep is the main risk to this project.

## Getting set up

Requires macOS 11+ and the Xcode **Command Line Tools**. Full Xcode is not
needed.

```sh
git clone https://github.com/Davin-X/nymbra.git
cd nymbra
make check
```

`make check` must pass on a clean clone before you change anything. If it does
not, that is a bug — please report it.

## Commands

| Command | Purpose |
|---|---|
| `make build` | Release build |
| `make lint` | Run SwiftLint (`brew install swiftlint`) |
| `make test` | Test harness (`NymbraCheck`) |
| `make pty-test` | Headless proof that a login shell runs on a PTY |
| `make check` | Everything CI runs — lint, build, tests, headless proofs |
| `make clean` | Remove build output |

## The architecture rule

```
Nymbra  ──▶  NymbraCore  ──▶  CPTY
```

- **`NymbraCore` and `CPTY` may not import `AppKit`, `SwiftUI`, `Metal`,
  `MetalKit`, `CoreText` or `QuartzCore`.**
- UI frameworks belong in the `Nymbra` target only.

This is not style: the emulator is the hard part, and it must be testable
without a window. `Scripts/check-architecture.sh` enforces it in CI, and your
pull request will fail if it is violated.

## Adding a dependency

Please don't, without an ADR. Runtime dependencies are ruled out by
[ADR-0001](docs/adr/0001-native-swift-zero-runtime-dependencies.md). If you
believe a case exists, open an issue describing what it buys, what it costs, and
what happens when it is abandoned upstream — before writing code.

Build tools that do not ship in the binary are a lower bar, but still worth
discussing.

## Coding conventions

- Swift API Design Guidelines; `UpperCamelCase` for types, `lowerCamelCase`
  elsewhere.
- Types and functions in `NymbraCore` that other targets need must be `public`;
  default to the narrowest access that works.
- Comment the **why**, not the what. Non-obvious constraints (like ADR-0002's
  startup order) must be commented at the point of danger.
- No force-unwrapping outside tests unless the invariant is locally obvious.
- Keep files focused: one concept per file, named after the concept.

## Tests

- Every behaviour change adds or updates a suite in `Sources/NymbraCheck/Suites/`.
- Bug fixes add a **regression test** that fails before the fix. No exceptions —
  the OSC parsing bug found during M0 is the model: the test exists so it can
  never come back.
- Parser work extends the conformance corpus rather than adding one-off cases.

Run `make test` before opening a pull request.

## Commits

[Conventional Commits](https://www.conventionalcommits.org):

```
feat(parser): handle DECAWM deferred wrap
fix(buffer): do not terminate OSC at the first printable byte
docs(roadmap): move mouse reporting to P1
test(parser): add 40 SGR conformance cases
chore(ci): cache the SwiftPM build
```

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `build`, `ci`, `chore`.

## Pull requests

- One logical change per pull request.
- Update `CHANGELOG.md` under `## [Unreleased]` for anything user-visible.
- Update the docs when behaviour or architecture changes — the documentation is
  part of the change, not a follow-up.
- **Definition of done:** builds clean, `make check` green, tests added for new
  behaviour, docs and changelog updated, no new dependency without an ADR.

## Reporting bugs

Please include: macOS version, `swift --version`, what you ran, what you
expected, what happened, and — for rendering bugs — which program produced the
output. A raw byte capture is gold for parser bugs.
