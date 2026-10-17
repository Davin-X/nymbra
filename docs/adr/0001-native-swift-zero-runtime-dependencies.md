# ADR-0001 — Native Swift, zero third-party runtime dependencies

**Status:** Accepted · 2026-10-17

## Context

The obvious way to build a terminal on macOS is to wrap an existing one:
an embedded web view with `xterm.js` (Hyper, Tabby), or a Swift UI over another
renderer (`cmux` uses `libghostty`). That is fast to ship and carries real cost:

- a browser engine in the dependency tree;
- a hard ceiling on rendering — no threaded PTY→render path, no glyph atlas, no
  ligatures, no image protocols without upstream changes;
- hundreds of transitive crates or packages to track for licensing and security;
- an application that cannot exceed the thing it wraps.

A predecessor prototype of Nymbra was exactly this (Tauri + `xterm.js`) and hit
that ceiling dependably.

## Decision

Nymbra is written in Swift against AppKit, CoreText and Metal, with a POSIX
PTY. It has **no third-party runtime dependencies**. The only non-Swift code is
a 25-line C shim for `forkpty()`.

Build tooling (`swiftc`, `clang`, `make`, GitHub Actions) is not counted: none
of it ships in the binary.

## Consequences

**Good**
- No dependency ceiling: ligatures, images, GPU rendering and a threaded parser
  are all reachable.
- `otool -L` proves the claim; nothing to audit for licences but Apple's SDK.
- Start-up and idle cost are ours to control.
- The name and the code are entirely ours.

**Bad**
- Emulation correctness is now our problem, and it is the hard 90%.
- No upstream to inherit bug fixes from.
- More code to write before the product is pleasant.

**Mitigations**
- Emulation is written from specifications (ECMA-48, `xterm` `ctlseqs`), not
  from another emulator's source — see ADR-0003 on avoiding GPL contamination.
- A conformance corpus plus fuzzing replaces the safety net a popular upstream
  would have provided.
