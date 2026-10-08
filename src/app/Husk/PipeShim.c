/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <errno.h>
#include <stdint.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include "fishhook.h"

/*
 * Implementation of pipe2 for iOS systems where libc does not export it.
 *
 * In macOS 15 / iOS 18 SDKs, pipe2 was introduced. When GLib was compiled
 * against those headers, it detected HAVE_PIPE2 and emitted weak calls to
 * pipe2(). On iOS 16 and 17 devices, libSystem does not implement pipe2,
 * so the weak symbol resolves to NULL at runtime, causing g_unix_open_pipe()
 * to branch to 0x0 and crash with SIGSEGV (signal 11) inside qemu_init().
 *
 * Using fishhook, we patch the GOT in our own images (the main binary and
 * libqemu-aarch64-softmmu.dylib) to point pipe2 to this implementation.
 *
 * IMPORTANT: do NOT run this from a dyld constructor. rebind_symbols() walks
 * every loaded image and vm_protect()s __DATA_CONST binding slots. On iOS 15
 * that can SIGKILL the process (AMFI) before main — no ReportCrash .ips, no
 * Documents/husk.log, just a black flash back to SpringBoard. Install the
 * shim from HuskApp.init after HuskLog.start() instead, and only touch our
 * own images.
 */

/* Runs before QEMU's default-priority constructors. If this file appears in
 * Documents but husk.log does not, the kill is still pre-main (likely a QEMU
 * static initializer). If neither appears, dyld died first. */
__attribute__((constructor(50)))
static void husk_ctor_breadcrumb(void)
{
    const char *home = getenv("HOME");
    if (!home) return;
    char path[768];
    int n = snprintf(path, sizeof path, "%s/Documents/husk-ctor.txt", home);
    if (n <= 0 || (size_t)n >= sizeof path) return;
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) return;
    const char msg[] = "ctors-begin\n";
    (void)write(fd, msg, sizeof msg - 1);
    close(fd);
}

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

static int image_is_ours(const char *name)
{
    if (!name) return 0;
    /* Main executable ends with /Husk.app/Husk; qemu dylib is under Frameworks. */
    if (strstr(name, "/Husk.app/Husk") != NULL) return 1;
    if (strstr(name, "libqemu-aarch64-softmmu") != NULL) return 1;
    return 0;
}

__attribute__((visibility("default")))
void husk_install_pipe2_shim(void)
{
    struct rebinding rebindings[] = {
        {"pipe2", (void *)pipe2, NULL}
    };
    uint32_t count = _dyld_image_count();
    uint32_t touched = 0;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!image_is_ours(name)) continue;
        rebind_symbols_image((void *)(uintptr_t)_dyld_get_image_header(i),
                             _dyld_get_image_vmaddr_slide(i),
                             rebindings, 1);
        touched++;
    }
    fprintf(stderr, "[pipe2-shim] rebind installed on %u own image(s)\n", touched);
}
