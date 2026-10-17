/* nymbra-spawn: give a program a controlling terminal, then become it.
 *
 * usage: nymbra-spawn <terminal-fd> <program> <argv0> [arguments...]
 *
 * The terminal descriptor is inherited, not opened here, and that is the point
 * of the program. It is already open in the caller and is passed across the
 * spawn untouched; this process becomes a session leader and claims it with
 * `TIOCSCTTY`, which is the same sequence login_tty(3) performs. Because the
 * descriptor exists in the child from the moment of the spawn, the terminal's
 * other end never has a moment without a holder, and the reader of that other
 * end therefore never mistakes the gap for the program exiting.
 *
 * The program and its `argv[0]` are separate arguments because they are
 * separate things: a login shell is started as `/bin/zsh` and answers to `zsh`,
 * and the name it is given is the name it trusts for login-shell behaviour.
 * Everything from `<argv0>` on is handed to `execv` unchanged.
 *
 * `posix_spawn` cannot do this, and the way it fails is quiet. A terminal is
 * three things at once — a device, a session leader, and a foreground process
 * group — and only the first two can be arranged from the parent: POSIX applies
 * the file actions *before* the spawn attributes, so a file action that opens
 * the slave runs while the child is still in the parent's session, where opening
 * a terminal cannot make it the controlling one. The session is then created
 * afterwards and the child is left with a terminal that has no foreground
 * process group at all.
 *
 * Nothing about that looks broken. The shell starts, prints its prompt, echoes
 * what is typed into it, runs commands and prints their output — because the
 * terminal's line discipline does all of that by itself. What is missing is
 * Ctrl+C, Ctrl+Z and hangup, none of which can be delivered, and any question
 * about whether a job is running, which `tcgetpgrp` answers with 0 forever.
 *
 * Opening by name after the session is created would fix that, but it would
 * trade one fault for another: the caller holds the far end of the terminal,
 * and a read of that end with no other holder reports end of file, so a reader
 * that started before this process got around to opening the device would see
 * the program "exit" immediately. Inheriting the descriptor is what makes the
 * handover unobservable.
 *
 * Reference: termios(4), tty(4), login_tty(3), posix_spawn(2).
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

/* Reported on the terminal itself, which puts the reason on the pane the user is
 * looking at instead of in a console log. The application's stderr is written to
 * as well, because the terminal is not a working channel until the descriptor
 * has been made stdin, stdout and stderr. */
static void fail(int terminal, const char *what) {
    char message[512];
    int length = snprintf(message, sizeof message, "nymbra-spawn: %s: %s\n",
                          what, strerror(errno));
    if (length > 0) {
        ssize_t written = write(STDERR_FILENO, message, (size_t)length);
        (void)written;
        if (terminal > STDERR_FILENO) {
            written = write(terminal, message, (size_t)length);
            (void)written;
        }
    }
}

int main(int argc, char **argv) {
    if (argc < 4) {
        dprintf(STDERR_FILENO,
                "usage: nymbra-spawn <terminal-fd> <program> <argv0> [arguments...]\n");
        return 2;
    }
    int terminal = atoi(argv[1]);
    const char *program = argv[2];
    char **program_argv = &argv[3];

    /* A descriptor below 3 would be one this process is about to replace with
     * the terminal itself, so the caller keeping the terminal above stderr is
     * part of the arrangement rather than an incidental detail. */
    if (terminal <= STDERR_FILENO || !isatty(terminal)) {
        dprintf(STDERR_FILENO,
                "nymbra-spawn: %s: not an open terminal descriptor\n", argv[1]);
        return 2;
    }

    /* A new session with no controlling terminal, which is the state the
     * terminal has to be claimed from. */
    if (getsid(0) != getpid() && setsid() == -1) {
        fail(terminal, "setsid");
        return 1;
    }

    /* The claim. The descriptor was opened elsewhere, and that does not matter:
     * `TIOCSCTTY` is a property of the terminal and of this process, not of how
     * the two were connected. It is also what makes the terminal's foreground
     * process group this process's, without which no signal meant for "the
     * program on the terminal" has anywhere to go. */
    if (ioctl(terminal, TIOCSCTTY, 0) == -1) {
        fail(terminal, "TIOCSCTTY");
        return 1;
    }

    /* The terminal becomes stdin, stdout and stderr before anything else can
     * fail, so that a failure is visible somewhere a person will look. */
    if (dup2(terminal, STDIN_FILENO) == -1) {
        fail(terminal, "dup2");
        return 1;
    }
    if (dup2(terminal, STDOUT_FILENO) == -1) {
        fail(terminal, "dup2");
        return 1;
    }
    if (dup2(terminal, STDERR_FILENO) == -1) {
        fail(terminal, "dup2");
        return 1;
    }
    if (terminal > STDERR_FILENO) {
        close(terminal);
    }

    /* Everything else this process was handed goes: the far end of this
     * terminal, the window server, whatever else an application has open. A
     * shell that inherits the master of its own terminal holds the pane open
     * after it exits, and a command it starts holds it open after that. */
    int limit = getdtablesize();
    for (int extra = STDERR_FILENO + 1; extra < limit; extra++) {
        close(extra);
    }

    /* No return from here. `argv[0]` is the name the program was asked to
     * answer to, which is not always the path it was found at: a shell started
     * as a login shell must see its bare name. */
    execv(program, program_argv);
    fail(STDERR_FILENO, program);
    return 127;
}
