#include "include/cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

pid_t cpty_spawn(int *master, unsigned short rows, unsigned short cols,
                 const char *path, char *const argv[], char *const envp[],
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

    /* ttyname() points into a static buffer that the next call would reuse, and
     * the file actions keep this string until posix_spawn returns. */
    const char *name = ttyname(slave_fd);
    if (name == NULL) {
        int saved = errno;
        close(master_fd);
        close(slave_fd);
        errno = saved;
        return -1;
    }
    char slave_path[128];
    strlcpy(slave_path, name, sizeof slave_path);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    /* Opening the slave *in the child* is what makes it the controlling
     * terminal, and it only works because the child is a session leader with no
     * terminal yet: the first tty a session leader opens becomes its
     * controlling terminal. Duplicating an already-open descriptor to fd 0
     * would hand the child a terminal without making it the controlling one,
     * and then there is no foreground process group — no Ctrl+C, no job
     * control, and `tcgetpgrp` answers 0. */
    posix_spawn_file_actions_addopen(&actions, 0, slave_path, O_RDWR, 0);
    posix_spawn_file_actions_adddup2(&actions, 0, 1);
    posix_spawn_file_actions_adddup2(&actions, 0, 2);
    posix_spawn_file_actions_addclose(&actions, slave_fd);

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
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, &actions, &attributes, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);

    /* The parent's copy of the slave is closed either way: while anyone holds it
     * open, the master reports no EOF when the shell exits. */
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
