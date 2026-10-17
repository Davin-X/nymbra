# ADR-0007 — Shells are started with `posix_spawn`, not `forkpty`

**Status:** Accepted · 2026-10-17 · supersedes [ADR-0002](0002-forkpty-before-appkit.md)

## Context

ADR-0002 made one window possible: spawn the shell with `forkpty()` *before*
AppKit is initialised, and keep the child to async-signal-safe calls. That was
correct as far as it went, and invariant 5 enforced it.

It also made a second shell impossible. `forkpty()` forks the application itself,
so once AppKit has started — threads, run loops, Mach ports, an initialised
Objective-C runtime — the fork is undefined behaviour and the child may not touch
anything but syscalls. Every feature that starts a shell *later* needs exactly
that:

- **New Window** (`⌘N`), and reopening one after the red button closed it.
- **Tabs and splits** (M1.x), where a new pane is a new shell.
- **Sessions** (M5), where a shell outlives the window that showed it.

The cost of the rule was real, not theoretical. CI reported this, unchanged, for
several commits while the first window was still forked:

```
objc[4452]: +[NSPathStore2 initialize] may have been in progress in another
thread when fork() was called ... Crashing instead.
```

The child called `(path as NSString).lastPathComponent` — ordinary Swift, fatal
after a fork. The shell never started, and because a PTY echoes what is typed
into it, the screen still filled with text: a dead child that read exactly like a
broken emulator. Closing the last window was a dead end for the same reason.

## Decision

Start every shell — the first one and every one after — with `openpty()` plus
`posix_spawn()`, and never `fork`:

```c
openpty(&master, &slave, NULL, NULL, &winsize);
posix_spawn_file_actions_addopen(&actions, 0, ttyname(slave), O_RDWR, 0);
posix_spawn_file_actions_adddup2(&actions, 0, 1);
posix_spawn_file_actions_adddup2(&actions, 0, 2);
posix_spawn_file_actions_addclose(&actions, slave);
posix_spawn_file_actions_addchdir_np(&actions, working_directory);
posix_spawnattr_setsigdefault(&attributes, /* SIGPIPE, SIGINT, SIGQUIT, SIGTERM,
                                              SIGHUP, SIGTSTP, SIGTTIN, SIGTTOU */);
posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF);
posix_spawn(&pid, path, &actions, &attributes, argv, envp);
```

Three parts of that are load-bearing and were verified rather than assumed:

1. **`addopen` on the slave path, not a duplicated descriptor.** The child is a
   session leader (`POSIX_SPAWN_SETSID`) with no terminal, and the first tty a
   session leader *opens* becomes its controlling terminal. Handing the child an
   already-open descriptor does not do this. Without it the shell runs, prints a
   prompt and echoes what you type, but there is no foreground process group —
   so Ctrl+C does nothing and `tcgetpgrp` answers 0. Nothing on screen says so.
2. **`POSIX_SPAWN_SETSIGDEF`.** Signals this process ignores are inherited. A GUI
   process commonly ignores `SIGPIPE`, and a shell that inherits that prints
   "broken pipe" where `yes | head -1` should be silent. The job-control signals
   have to be default for the tty driver to stop a background job.
3. **An explicit working directory.** A process opened from the Finder or the Dock
   starts in `/`, and a shell in `/` cannot `mkdir`. `addchdir_np` moves the child
   without `chdir()`ing the application out from under its own threads, and `PWD`
   is set to match, because shells trust it.

## Consequences

- **Invariant 5 becomes stronger, not weaker.** There is now no post-fork code at
  all: `posix_spawn` execs without running anything of ours in between, so the
  class of bug above is unrepresentable rather than merely avoided. The rule "the
  child may only call async-signal-safe POSIX" no longer has a subject.
- **No ordering constraint.** `spawnShell()` may be called at any point, so the
  first window is created the same way as every other one. `main.swift` no longer
  spawns anything before `NSApplication.shared`, and `AppController.makeWindow()`
  is the single path.
- **Spawn failures are reported by the parent**, before any shell exists: `errno`
  from `posix_spawn` becomes `PTYError.spawnFailed(shell:reason:)`, which the
  application shows in an alert. Previously the child wrote its own failure
  message onto the terminal, which no longer has a child to write it.
- **Verified by tests, because every failure above is silent.** `PTYSuite` now
  asks the kernel: the shell is the terminal's foreground process group, a
  foreground job gets its own group, Ctrl+C ends that job and hands the terminal
  back, `SIGPIPE` is default, `/bin/pwd` prints the directory the shell was told
  to use, and eight shells start while other threads allocate and initialise
  Foundation types — the situation the old rule existed to avoid.
- The `--pty-test` flag still runs a real login shell on a real PTY. It prints
  `tty` and `/bin/pwd` as well, so a CI log shows the terminal the shell got and
  the directory it started in.
