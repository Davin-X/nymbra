#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

/* Fork a login shell onto a new pseudo-terminal.
 * Returns the child pid in the parent, 0 in the child (which must exec),
 * and -1 on failure. The master fd is written to *master. */
pid_t cpty_spawn(int *master, unsigned short rows, unsigned short cols);

/* Tell the kernel the window changed size (TIOCSWINSZ). */
int cpty_resize(int master, unsigned short rows, unsigned short cols);

#endif /* CPTY_H */
