#ifndef GHOSTTY_PTY_COMPAT_H
#define GHOSTTY_PTY_COMPAT_H
/* forkpty is declared in different headers on Linux and Darwin. */
#if defined(__APPLE__)
#include <util.h>
#else
#include_next <pty.h>
#endif
#endif
