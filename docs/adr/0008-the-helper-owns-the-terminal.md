# ADR-0008 — A helper program claims the terminal, from an inherited descriptor

**Status:** Accepted · 2026-10-17 · corrects a claim in
[ADR-0007](0007-posix-spawn-instead-of-forkpty.md)

## Context

[ADR-0007](0007-posix-spawn-instead-of-forkpty.md) replaced `forkpty()` with
`openpty()` + `posix_spawn()`. The part that mattered for safety was right, and
still is: `fork()` is not called, so a half-forked copy of a process with an
initialised Objective-C runtime and running threads is unrepresentable.

It also made a claim that is false, and the falseness was invisible for the same
reason the bug it replaced was invisible. The claim, from its decision section:

> **`addopen` on the slave path, not a duplicated descriptor.** The child is a
> session leader (`POSIX_SPAWN_SETSID`) with no terminal, and the first tty a
> session leader *opens* becomes its controlling terminal. Handing the child an
> already-open descriptor does not do this.

POSIX applies the **file actions before the spawn attributes**. So the open ran
while the child was still in the *parent's* session, and opening a terminal
cannot make it the controlling terminal of a process that is not a session
leader. `POSIX_SPAWN_SETSID` created the session afterwards. The result was a
shell in a session whose terminal had:

- **no foreground process group** — `tcgetpgrp(master)` answered `0` for the life
  of the shell, and `ps` showed `TPGID 0` for it;
- therefore **no way to deliver a signal to the program on the terminal**:
  Ctrl+C, Ctrl+Z and hangup had no destination;
- therefore **no job control**. zsh turns it off, silently, when it cannot find
  its controlling terminal, which is why the symptom was "Ctrl+C does nothing"
  rather than an error.

Everything else worked, which is why this survived a release. The prompt
appeared, keystrokes echoed, commands ran, output rendered — the line discipline
does all of that by itself. Nothing on the screen said that the terminal had no
foreground process group.

It was found by the first M1.x test that asked the question directly: four panes,
each running a different program, each required to interrupt its own job without
touching any other. Two shells that *look* correct — `/bin/sh` among them — cannot
answer it, because bash reacquires a terminal for itself. `/bin/sleep`, which
never touches its terminal, can.

## Decision

The terminal is claimed by a program, `NymbraSpawn`, which is exec'd in the
child's place and becomes the shell:

```c
/* nymbra-spawn <terminal-fd> <program> <argv0> [arguments...] */
setsid();                                  /* a session with no terminal  */
ioctl(terminal, TIOCSCTTY, 0);             /* the claim                   */
dup2(terminal, 0); dup2(terminal, 1); dup2(terminal, 2);
close them all, 3 .. getdtablesize();      /* inherit nothing else        */
execv(program, argv);                      /* this process *is* the shell */
```

Four parts of that are load-bearing, and each was verified rather than assumed.

1. **The session is created in the child, by the child.** `posix_spawn` cannot
   express "setsid, then claim the terminal": file actions run before attributes,
   and there is no attribute for `ioctl`. So `POSIX_SPAWN_SETSID` is gone — the
   session is the helper's business — and only `POSIX_SPAWN_SETSIGDEF` remains.
2. **The terminal descriptor is inherited, not opened by name.** Opening by name
   after the session exists does fix the controlling-terminal problem, and it
   introduces a different one: a read of the master with **no slave open reports
   end of file immediately** (measured, blocking, on this platform). The
   application's reader starts as soon as the spawn returns, so a
   name-opened slave leaves a window in which the reader sees a phantom EOF and
   concludes the shell has exited. Inheriting the descriptor removes the window:
   the child holds the terminal from the moment of the spawn, so the handover is
   unobservable, whatever the two processes do afterwards.
3. **The parent closes its own copy of the slave the instant the spawn returns**,
   and the child closes every descriptor above stderr before `exec`. While *any*
   process holds the slave open, the master never reports end of file — so a leak
   here is a pane that stays open for good after its shell has exited, and a
   shell that inherits the master of its own terminal passes that problem on to
   every command it runs. `FD_CLOEXEC` is set on the master for the same reason.
4. **The helper is looked for beside the running executable**, not in a fixed
   place: `NYMBRA_SPAWN` overrides, else the directory of `Bundle.main`'s
   executable. The two travel together — `.build/release/` when the package is
   built, `Contents/MacOS/` inside the application bundle — and a terminal that
   cannot find the helper cannot start a shell at all, so `make app` copies it
   and `PTYSuite` asserts it is where the app will look.

`TIOCSCTTY` on an inherited descriptor is not a workaround. It is what
`login_tty(3)` does, and what `forkpty()` does for every terminal on the system:
a descriptor and its claim are separate facts, and `open()` only *sometimes*
implies the second one.

## Consequences

- **Ctrl+C, Ctrl+Z and hangup now work**, and `tcgetpgrp(master)` answers the
  shell's pid. Before and after, as printed by the same command in the same
  session:

  | | foreground group | a job of its own | Ctrl+C ends it |
  |---|---|---|---|
  | `openpty` + `addopen` (ADR-0007) | `0` | no | no |
  | `NymbraSpawn` (this ADR) | the shell's pid | yes | yes |

- **The exec path is unchanged, and the important half of ADR-0007 stands.** The
  process that claims the terminal is a freshly `exec`'d program, not a forked
  copy of the application: `posix_spawn` still execs without running any of our
  code in between, and the helper runs in a process image that has never held
  AppKit. Invariant 5 is restated in `docs/ARCHITECTURE.md` in those terms.
- **There is now more than one C target.** `CPTY` opens the terminal and starts
  the helper; `NymbraSpawn` claims the terminal. Both are C, both are tiny, and
  neither imports anything of ours. The architecture guard covers both.
- **A missing helper is a hard failure with a readable message.**
  `PTYError.spawnHelperNotFound` names the path that was tried, because "cannot
  find the spawn helper at …" is a fixable sentence and a pane that never appears
  is not.
- **The suite had to learn to be a terminal.** While chasing this, the tests
  exposed their own version of the same class of bug: the kernel's buffer between
  a terminal and its reader is about **1024 bytes**, and a program that has filled
  it blocks in `write` — including a shell halfway through drawing its prompt,
  which then never reads the next command. A test that stops reading between
  assertions is testing a terminal that does not exist, and one that does it can
  hang a shell in an unkillable `exit`. `PTYSuite` now drains while it waits, and
  every blocked wait has a deadline.
- **What the failure looked like is recorded in the suite**, because the next
  version of it will look different: `/bin/sleep` never touches its terminal and
  is asked whether it has one; zsh is asked whether a job gets its own process
  group and whether Ctrl+C hands the terminal back; the shell is asked whether it
  can see the master of its own terminal by number.
