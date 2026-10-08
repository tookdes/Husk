/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/*
 * pipe2 fallback for iOS < 18.
 *
 * Prefer rebuilding GLib with HAVE_PIPE2 forced off (see scripts/build_ios.sh):
 * that removes the weak NULL calls entirely. This symbol remains exported so a
 * stale libqemu that still weak-imports pipe2 can bind to us without fishhook.
 *
 * Do NOT fishhook / vm_protect __DATA_CONST here. On iPadOS 15.4.1 that AMFI
 * SIGKILLs at launch: black flash, empty Documents, no Analytics .ips.
 */

__attribute__((visibility("default")))
int pipe2(int fds[2], int flags)
{
    if (!fds) {
        errno = EFAULT;
        return -1;
    }
    if (pipe(fds) < 0) {
        return -1;
    }
    if (flags & O_CLOEXEC) {
        if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 ||
            fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0) {
            int err = errno;
            close(fds[0]);
            close(fds[1]);
            errno = err;
            return -1;
        }
    }
    if (flags & O_NONBLOCK) {
        int f0 = fcntl(fds[0], F_GETFL);
        int f1 = fcntl(fds[1], F_GETFL);
        if (f0 < 0 || f1 < 0 ||
            fcntl(fds[0], F_SETFL, f0 | O_NONBLOCK) < 0 ||
            fcntl(fds[1], F_SETFL, f1 | O_NONBLOCK) < 0) {
            int err = errno;
            close(fds[0]);
            close(fds[1]);
            errno = err;
            return -1;
        }
    }
    return 0;
}

/* Earliest app-image breadcrumb. Dependency dylibs (libqemu) run their
 * constructors first; if Documents stays empty after install, dyld/AMFI died
 * before this image's constructors. mkdir Documents: it does not exist yet
 * at constructor time on a fresh container. */
__attribute__((constructor(50)))
static void husk_ctor_breadcrumb(void)
{
    const char *home = getenv("HOME");
    if (!home || !*home) return;
    char doc[768];
    int n = snprintf(doc, sizeof doc, "%s/Documents", home);
    if (n <= 0 || (size_t)n >= sizeof doc) return;
    (void)mkdir(doc, 0755);
    char path[800];
    n = snprintf(path, sizeof path, "%s/husk-ctor.txt", doc);
    if (n <= 0 || (size_t)n >= sizeof path) return;
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) return;
    const char msg[] = "ctors-app-begin\n";
    (void)write(fd, msg, sizeof msg - 1);
    close(fd);
}

/* Kept for ABI with HuskBridge.h; no-op now that fishhook is gone. */
__attribute__((visibility("default")))
void husk_install_pipe2_shim(void)
{
    /* no-op: GLib is built without pipe2; fishhook removed (AMFI SIGKILL). */
}
