#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

/* Run `path` on a new pseudo-terminal, with that terminal as the child's
 * controlling terminal, in the directory `working_directory`.
 *
 * Returns the child pid, or -1 with errno set (to the value posix_spawn
 * reported, which is an errno value rather than -1). The master fd is written
 * to *master on success and left untouched on failure.
 *
 * This replaced forkpty(). forkpty forks the calling process, which is only
 * defined behaviour while it is single-threaded: a second shell — a new window,
 * a tab, a split — has to be started with AppKit already running, and that is
 * exactly the case ADR-0002 was working around. posix_spawn execs without
 * running any of this process's code in between (ADR-0007). */
pid_t cpty_spawn(int *master, unsigned short rows, unsigned short cols,
                 const char *path, char *const argv[], char *const envp[],
                 const char *working_directory);

/* Tell the kernel the window changed size (TIOCSWINSZ). */
int cpty_resize(int master, unsigned short rows, unsigned short cols);

#endif /* CPTY_H */
