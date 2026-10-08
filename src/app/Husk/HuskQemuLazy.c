/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Lazy-load libqemu-aarch64-softmmu.dylib AFTER the SwiftUI UI is up.
 *
 * Evidence on iPadOS 15.4.1 TrollStore (builds 30–32): black flash, empty
 * Documents, no Analytics .ips. The main binary LC_LOAD_DYLIB'd a 33 MB
 * libqemu with ~809 __init_offsets constructors at process start. Combined
 * with the banned `dynamic-codesigning` entitlement on A12+ iOS 15 (see
 * TrollStore README), AMFI/dyld can SIGKILL before any of our constructors
 * run. Embedding without linking + dlopen after first frame isolates that.
 */
#include "HuskBridge.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/task.h>
#include <mach/task_info.h>
#include <os/proc.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static void *g_qemu;
static char g_err[512];

static void breadcrumb(const char *name, const char *msg)
{
    const char *bases[3];
    int nbase = 0;
    const char *home = getenv("HOME");
    const char *tmp = getenv("TMPDIR");
    const char *cff = getenv("CFFIXED_USER_HOME");
    if (home && *home) bases[nbase++] = home;
    if (cff && *cff) bases[nbase++] = cff;
    if (tmp && *tmp) bases[nbase++] = tmp;

    for (int i = 0; i < nbase; i++) {
        char dir[768];
        if (bases[i] == tmp) {
            snprintf(dir, sizeof dir, "%s", bases[i]);
        } else {
            snprintf(dir, sizeof dir, "%s/Documents", bases[i]);
            (void)mkdir(dir, 0755);
        }
        char path[900];
        snprintf(path, sizeof path, "%s/%s", dir, name);
        int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (fd < 0) continue;
        (void)write(fd, msg, strlen(msg));
        close(fd);
    }
    /* Absolute last resort: container tmp is often TMPDIR; also try /tmp. */
    int fd = open("/tmp/husk-lazy.txt", O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        (void)write(fd, msg, strlen(msg));
        close(fd);
    }
}

static void *must_sym(const char *name)
{
    void *p = dlsym(g_qemu, name);
    if (!p) {
        snprintf(g_err, sizeof g_err, "dlsym(%s): %s", name, dlerror());
        breadcrumb("husk-qemu-dlsym-fail.txt", g_err);
    }
    return p;
}

/* Function pointers resolved once on first ensure. */
static void (*p_qemu_init)(int, char **);
static void (*p_qemu_main_loop)(void);
static void (*p_qemu_cleanup)(void);
static void (*p_husk_display_init)(void);
static bool (*p_husk_display_lock_frame)(HuskFrameInfo *);
static void (*p_husk_display_unlock_frame)(void);
static uint64_t (*p_husk_display_sequence)(void);
static void (*p_husk_display_send_pointer)(int32_t, int32_t, bool);
static bool (*p_husk_display_send_key)(const char *, bool);
static void (*p_husk_display_request_update)(void);
static void (*p_husk_ios_jit_install_trap_handler)(void);
static bool (*p_husk_ios_jit_prewarm)(size_t);
static bool (*p_husk_ios_jit_is_available)(void);
static bool (*p_husk_ios_jit_mapjit_works)(void);
static void (*p_husk_ios_jit_invalidate_probe_cache)(void);
static void (*p_husk_ios_jit_detach)(void);
static void (*p_husk_ios_jit_log_footprint)(const char *);
static size_t (*p_husk_ios_available_memory)(void);
static bool (*p_husk_display_gl_early)(void);
static bool (*p_husk_display_gl_create)(void *, int32_t, int32_t);
static bool (*p_husk_display_gl_probe)(void);
static bool (*p_husk_display_gl_bind)(void);
static uint64_t (*p_husk_display_gl_frames)(void);
static void (*p_husk_display_set_ui_size)(int32_t, int32_t);
static void (*p_husk_display_guest_size)(int32_t *, int32_t *);
static int32_t (*p_husk_audio_pull)(int16_t *, int32_t);
static bool (*p_husk_audio_active)(void);
static uint64_t (*p_husk_audio_frames_in)(void);
static uint64_t (*p_husk_audio_underruns)(void);
static void (*p_husk_display_gl_set_metal_presenter)(husk_metal_present_fn);
static bool (*p_husk_snapshot_load_at_startup)(void);
static void (*p_husk_snapshot_save)(void (*)(bool, const char *));
static void (*p_husk_balloon_set_bytes)(int64_t);

static void load_qemu_once(void)
{
    breadcrumb("husk-qemu-before-dlopen.txt", "about-to-dlopen-libqemu\n");

    const char *path = NULL;
    Dl_info info;
    if (dladdr((const void *)load_qemu_once, &info) && info.dli_fname) {
        /* Prefer sibling Frameworks next to the main executable. */
        static char buf[1024];
        const char *slash = strrchr(info.dli_fname, '/');
        if (slash) {
            size_t n = (size_t)(slash - info.dli_fname);
            if (n + 64 < sizeof buf) {
                memcpy(buf, info.dli_fname, n);
                snprintf(buf + n, sizeof buf - n,
                         "/Frameworks/libqemu-aarch64-softmmu.dylib");
                path = buf;
            }
        }
    }
    if (!path) {
        path = "@executable_path/Frameworks/libqemu-aarch64-softmmu.dylib";
    }

    g_qemu = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!g_qemu) {
        snprintf(g_err, sizeof g_err, "dlopen(%s): %s", path, dlerror());
        breadcrumb("husk-qemu-dlopen-fail.txt", g_err);
        return;
    }
    breadcrumb("husk-qemu-after-dlopen.txt", "dlopen-ok-ctors-ran\n");

#define RESOLVE(name) p_##name = must_sym(#name)
    RESOLVE(qemu_init);
    RESOLVE(qemu_main_loop);
    RESOLVE(qemu_cleanup);
    RESOLVE(husk_display_init);
    RESOLVE(husk_display_lock_frame);
    RESOLVE(husk_display_unlock_frame);
    RESOLVE(husk_display_sequence);
    RESOLVE(husk_display_send_pointer);
    RESOLVE(husk_display_send_key);
    RESOLVE(husk_display_request_update);
    RESOLVE(husk_ios_jit_install_trap_handler);
    RESOLVE(husk_ios_jit_prewarm);
    RESOLVE(husk_ios_jit_is_available);
    RESOLVE(husk_ios_jit_mapjit_works);
    RESOLVE(husk_ios_jit_invalidate_probe_cache);
    RESOLVE(husk_ios_jit_detach);
    RESOLVE(husk_ios_jit_log_footprint);
    RESOLVE(husk_ios_available_memory);
    RESOLVE(husk_display_gl_early);
    RESOLVE(husk_display_gl_create);
    RESOLVE(husk_display_gl_probe);
    RESOLVE(husk_display_gl_bind);
    RESOLVE(husk_display_gl_frames);
    RESOLVE(husk_display_set_ui_size);
    RESOLVE(husk_display_guest_size);
    RESOLVE(husk_audio_pull);
    RESOLVE(husk_audio_active);
    RESOLVE(husk_audio_frames_in);
    RESOLVE(husk_audio_underruns);
    RESOLVE(husk_display_gl_set_metal_presenter);
    RESOLVE(husk_snapshot_load_at_startup);
    RESOLVE(husk_snapshot_save);
    RESOLVE(husk_balloon_set_bytes);
#undef RESOLVE
}

bool husk_ensure_qemu_loaded(void)
{
    pthread_once(&g_once, load_qemu_once);
    return g_qemu != NULL && p_qemu_init != NULL;
}

const char *husk_qemu_load_error(void)
{
    pthread_once(&g_once, load_qemu_once);
    return g_err[0] ? g_err : NULL;
}

/* --- wrappers (link symbols previously provided by LC_LOAD_DYLIB) --- */

void qemu_init(int argc, char **argv)
{
    if (!husk_ensure_qemu_loaded() || !p_qemu_init) return;
    p_qemu_init(argc, argv);
}
void qemu_main_loop(void)
{
    if (!husk_ensure_qemu_loaded() || !p_qemu_main_loop) return;
    p_qemu_main_loop();
}
void qemu_cleanup(void)
{
    if (!husk_ensure_qemu_loaded() || !p_qemu_cleanup) return;
    p_qemu_cleanup();
}

void husk_display_init(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_init) return;
    p_husk_display_init();
}
bool husk_display_lock_frame(HuskFrameInfo *out)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_lock_frame) return false;
    return p_husk_display_lock_frame(out);
}
void husk_display_unlock_frame(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_unlock_frame) return;
    p_husk_display_unlock_frame();
}
uint64_t husk_display_sequence(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_sequence) return 0;
    return p_husk_display_sequence();
}
void husk_display_send_pointer(int32_t x, int32_t y, bool button_down)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_send_pointer) return;
    p_husk_display_send_pointer(x, y, button_down);
}
bool husk_display_send_key(const char *qcode_name, bool down)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_send_key) return false;
    return p_husk_display_send_key(qcode_name, down);
}
void husk_display_request_update(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_request_update) return;
    p_husk_display_request_update();
}

void husk_ios_jit_install_trap_handler(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_ios_jit_install_trap_handler) return;
    p_husk_ios_jit_install_trap_handler();
}
bool husk_ios_jit_prewarm(size_t bytes)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_ios_jit_prewarm) return false;
    return p_husk_ios_jit_prewarm(bytes);
}
bool husk_ios_jit_is_available(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_ios_jit_is_available) return false;
    return p_husk_ios_jit_is_available();
}
bool husk_ios_jit_mapjit_works(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_ios_jit_mapjit_works) return false;
    return p_husk_ios_jit_mapjit_works();
}
void husk_ios_jit_invalidate_probe_cache(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_ios_jit_invalidate_probe_cache) return;
    p_husk_ios_jit_invalidate_probe_cache();
}
void husk_ios_jit_detach(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_ios_jit_detach) return;
    p_husk_ios_jit_detach();
}

void husk_ios_jit_log_footprint(const char *tag)
{
    if (g_qemu && p_husk_ios_jit_log_footprint) {
        p_husk_ios_jit_log_footprint(tag);
        return;
    }
    /* Pre-dlopen stub: do not force-load qemu just for a log line. */
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        fprintf(stderr, "[husk] footprint(%s) phys_footprint=%llu (qemu not loaded yet)\n",
                tag ? tag : "?", (unsigned long long)info.phys_footprint);
    }
}

size_t husk_ios_available_memory(void)
{
    if (g_qemu && p_husk_ios_available_memory)
        return p_husk_ios_available_memory();
    /* Pre-dlopen stub — do not force-load qemu. */
    return (size_t)os_proc_available_memory();
}

bool husk_display_gl_early(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_gl_early) return false;
    return p_husk_display_gl_early();
}
bool husk_display_gl_create(void *native_layer, int32_t width, int32_t height)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_gl_create) return false;
    return p_husk_display_gl_create(native_layer, width, height);
}
bool husk_display_gl_probe(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_gl_probe) return false;
    return p_husk_display_gl_probe();
}
bool husk_display_gl_bind(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_gl_bind) return false;
    return p_husk_display_gl_bind();
}
uint64_t husk_display_gl_frames(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_gl_frames) return 0;
    return p_husk_display_gl_frames();
}
void husk_display_set_ui_size(int32_t width, int32_t height)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_set_ui_size) return;
    p_husk_display_set_ui_size(width, height);
}
void husk_display_guest_size(int32_t *width, int32_t *height)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_guest_size) return;
    p_husk_display_guest_size(width, height);
}

int32_t husk_audio_pull(int16_t *dst, int32_t frames)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_audio_pull) {
        if (dst && frames > 0) memset(dst, 0, (size_t)frames * 2 * sizeof(int16_t));
        return frames;
    }
    return p_husk_audio_pull(dst, frames);
}
bool husk_audio_active(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_audio_active) return false;
    return p_husk_audio_active();
}
uint64_t husk_audio_frames_in(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_audio_frames_in) return 0;
    return p_husk_audio_frames_in();
}
uint64_t husk_audio_underruns(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_audio_underruns) return 0;
    return p_husk_audio_underruns();
}

void husk_display_gl_set_metal_presenter(husk_metal_present_fn fn)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_display_gl_set_metal_presenter) return;
    p_husk_display_gl_set_metal_presenter(fn);
}

bool husk_snapshot_load_at_startup(void)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_snapshot_load_at_startup) return false;
    return p_husk_snapshot_load_at_startup();
}
void husk_snapshot_save(void (*cb)(bool ok, const char *what))
{
    if (!husk_ensure_qemu_loaded() || !p_husk_snapshot_save) {
        if (cb) cb(false, "qemu not loaded");
        return;
    }
    p_husk_snapshot_save(cb);
}
void husk_balloon_set_bytes(int64_t target_bytes)
{
    if (!husk_ensure_qemu_loaded() || !p_husk_balloon_set_bytes) return;
    p_husk_balloon_set_bytes(target_bytes);
}
