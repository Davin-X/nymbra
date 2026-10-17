#include "include/cpty.h"

#include <util.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

pid_t cpty_spawn(int *master, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return forkpty(master, NULL, NULL, &ws);
}

int cpty_resize(int master, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(master, TIOCSWINSZ, &ws);
}
