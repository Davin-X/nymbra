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
child does nothing but `execve`, `write` and `_exit`.

**Amendment, 2026-10-17.** The original decision here said the child would do
"nothing but `setenv`, `execv` and `_exit`". That was not what the code did, and
the difference was not academic: the child also computed `basename` with
`(shellPath as NSString).lastPathComponent`, which bridges a Swift `String` into
the Objective-C runtime. CI then collected, verbatim:

```
objc[4452]: +[NSPathStore2 initialize] may have been in progress in another
thread when fork() was called. We cannot safely call it or ignore it in the
fork() child process. Crashing instead.
```

The child aborted before `exec`. Because a PTY's line discipline echoes what is
written to it, the terminal still filled with the command that had been typed —
so the failure looked exactly like a working shell that ignored `TERM`, and it
survived several rounds of theorising about shells and runners.

The rule is therefore narrowed from "before AppKit" to **the child may call
nothing but async-signal-safe POSIX functions**. Everything else — the path, the
argument vector, the environment, even the bytes of the message printed when
`execve` fails — is built in the parent, because allocating or bridging after
the fork can take a lock the parent held at that instant.

`setenv` was dropped for the same reason: it is not async-signal-safe. The
environment is assembled in the parent and passed to `execve`.

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
