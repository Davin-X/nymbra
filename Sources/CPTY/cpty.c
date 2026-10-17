#include "include/cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

pid_t cpty_spawn(int *master, unsigned short rows, unsigned short cols,
                 const char *helper, const char *path,
                 char *const argv[], char *const envp[],
                 const char *working_directory) {
    int master_fd = -1;
    int slave_fd = -1;
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;

    if (openpty(&master_fd, &slave_fd, NULL, NULL, &ws) == -1) {
        return -1;
    }

    /* The child inherits this descriptor, so it has to survive the exec of the
     * helper, and it has to sit above stderr: the helper turns it into fd 1's
     * neighbours, and a terminal that arrived as fd 1 would be indistinguishable
     * from the stdio it is meant to replace. `openpty` gives the lowest free
     * descriptor, so a caller with a closed stdout could be handed 1 or 2.
     * `F_DUPFD` copies without the close-on-exec flag, which is what is wanted
     * here — this one is meant to be inherited. */
    if (slave_fd <= STDERR_FILENO) {
        int raised = fcntl(slave_fd, F_DUPFD, STDERR_FILENO + 1);
        if (raised == -1) {
            int saved = errno;
            close(master_fd);
            close(slave_fd);
            errno = saved;
            return -1;
        }
        close(slave_fd);
        slave_fd = raised;
    }

    /* The master must not follow the shell. It is the other end of the shell's
     * own terminal, and a process that holds it keeps the pane alive after the
     * shell it belongs to has exited; openpty() sets no close-on-exec flag, so
     * without this the descriptor is inherited by every command the shell runs.
     * (The helper closes whatever is left over, in the child, as well.) */
    int master_flags = fcntl(master_fd, F_GETFD);
    if (master_flags != -1) {
        fcntl(master_fd, F_SETFD, master_flags | FD_CLOEXEC);
    }

    /* The helper's arguments: the descriptor holding the terminal to claim, then
     * the program to become and its own arguments, exactly as they were given.
     * argv[0] is passed through unchanged, so a login shell still sees the name
     * it expects. The descriptor is passed as a number because that is all a
     * child needs: it is the same descriptor, in the same table, on the other
     * side of the spawn. */
    char terminal_argument[16];
    snprintf(terminal_argument, sizeof terminal_argument, "%d", slave_fd);

    size_t argc = 0;
    while (argv[argc] != NULL) {
        argc++;
    }
    char **helper_argv = malloc((argc + 4) * sizeof(char *));
    if (helper_argv == NULL) {
        close(master_fd);
        close(slave_fd);
        errno = ENOMEM;
        return -1;
    }
    helper_argv[0] = (char *)helper;
    helper_argv[1] = terminal_argument;
    helper_argv[2] = (char *)path;
    for (size_t index = 0; index < argc; index++) {
        helper_argv[3 + index] = argv[index];
    }
    helper_argv[3 + argc] = NULL;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    /* No file action opens the terminal. One that did would run before the
     * child's session exists, where the open cannot make it the controlling
     * terminal — the failure this whole arrangement exists to avoid (ADR-0008)
     * — and it would also be unnecessary: the child already has the descriptor
     * by inheritance, which is very nearly the opposite arrangement. */

    /* Where the shell starts. A GUI process does not inherit a useful working
     * directory — an application opened from the Finder or the Dock starts in
     * "/" — and a shell in "/" cannot even `mkdir`. Set in the child rather
     * than by chdir()ing this process, which would move the application's own
     * working directory out from under its other threads. */
    if (working_directory != NULL) {
        posix_spawn_file_actions_addchdir_np(&actions, working_directory);
    }

    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    /* The child must not inherit this process's dispositions. SIGPIPE is the one
     * that shows: a GUI process commonly ignores it, and a shell that inherits
     * that arrangement prints "broken pipe" where `yes | head` should be
     * silent. The job-control signals have to be default for the tty driver to
     * stop a background job. */
    sigset_t defaults;
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE);
    sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGQUIT);
    sigaddset(&defaults, SIGTERM);
    sigaddset(&defaults, SIGHUP);
    sigaddset(&defaults, SIGTSTP);
    sigaddset(&defaults, SIGTTIN);
    sigaddset(&defaults, SIGTTOU);
    posix_spawnattr_setsigdefault(&attributes, &defaults);

    /* `POSIX_SPAWN_SETSIGDEF`, and deliberately not `POSIX_SPAWN_SETSID`: the
     * session is the helper's to create, because creating it here would happen
     * after the file actions and could not be seen by any of them. */
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGDEF);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, helper, &actions, &attributes,
                         helper_argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    free(helper_argv);

    /* This process's copy of the slave goes now that the child has its own.
     * Holding it would be a leak with a visible symptom rather than a quiet
     * one: while *anyone* holds the slave open, the master never reports end of
     * file, so the pane would stay open for good after the shell exited. The
     * close cannot come earlier — the descriptor has to be here for the child
     * to inherit — and it cannot come later, or the window between the shell
     * exiting and this process noticing would never close. */
    close(slave_fd);

    if (rc != 0) {
        close(master_fd);
        errno = rc;
        return -1;
    }

    *master = master_fd;
    return pid;
}

int cpty_resize(int master, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(master, TIOCSWINSZ, &ws);
}
