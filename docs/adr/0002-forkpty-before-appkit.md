# ADR-0002 — `forkpty()` runs before AppKit starts

**Status:** Accepted · 2026-10-17

## Context

The shell must have a controlling terminal, which means `forkpty()` (or an
equivalent `posix_openpt` + `fork` + `ioctl(TIOCSCTTY)` sequence).

On macOS, calling `fork()` in a process that already has multiple threads and
live Mach ports is unsafe: the child inherits locks and ports in an
indeterminate state, and only async-signal-safe calls are legal until `exec`.
AppKit starts threads, installs run-loop observers and opens Mach ports the
moment it is initialised.

## Decision

`spawnShell()` is called **before** `NSApplication.shared` is touched, and the
child does nothing but `setenv`, `execv`, and `_exit`.

## Consequences

**Good**
- The only fork in the process happens while it is still single-threaded, which
  is the documented-safe window.
- No mutex or port hazards in the child.

**Bad**
- Terminal size must be known before the window exists, so the PTY is opened at
  the initial grid size and corrected with `TIOCSWINSZ` immediately after.
- The constraint is invisible and easy to break by "tidying up" the startup
  order. It is noted in `PTY.swift` and in `ARCHITECTURE.md`.

**Alternatives rejected**
- `posix_spawn` with `POSIX_SPAWN_SETSID`: attractive because it is thread-safe,
  but the interaction between `SETSID` ordering and the necessary controlling
  terminal (`TIOCSCTTY`) is subtle, and correctness was not worth the risk at
  this stage. Revisit for M5, where the PTY host moves out of process.
