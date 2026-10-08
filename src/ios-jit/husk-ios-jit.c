/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Husk -- iOS dual-mapped JIT memory for QEMU's TCG.  See husk-ios-jit.h.
 *
 * Derived from AetherPS4-iOS's src/core/ios/ios_jit_allocator.cpp
 * (shadPS4 Emulator Project, GPL-2.0-or-later), ported C++ -> C.
 */

#include "husk-ios-jit.h"

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && TARGET_OS_IPHONE

#include <errno.h>
#include <mach/mach.h>
#include <mach/vm_map.h>        /* vm_remap/vm_protect: mach_vm.h is absent from the iOS SDK */
#include <os/log.h>
#include <os/proc.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <mach/task.h>
#include <mach/task_info.h>
#include <libkern/OSCacheControl.h>
#include <sys/ucontext.h>   /* not <ucontext.h>: that one #errors without _XOPEN_SOURCE */
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/sysctl.h>

/* Runs when libqemu is dlopened (no longer at process start). mkdir
 * Documents — it does not exist yet in a fresh container. */
static void husk_qemu_write_marker(const char *dir, const char *file, const char *msg)
{
    (void)mkdir(dir, 0755);
    char path[900];
    int n = snprintf(path, sizeof path, "%s/%s", dir, file);
    if (n <= 0 || (size_t)n >= sizeof path) return;
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) return;
    (void)write(fd, msg, strlen(msg));
    close(fd);
}

__attribute__((constructor(101)))
static void husk_qemu_ctor_breadcrumb(void)
{
    const char msg[] = "ctors-qemu-begin\n";
    const char *home = getenv("HOME");
    const char *cff = getenv("CFFIXED_USER_HOME");
    const char *tmp = getenv("TMPDIR");
    char doc[768];
    if (home && *home) {
        snprintf(doc, sizeof doc, "%s/Documents", home);
        husk_qemu_write_marker(doc, "husk-qemu-ctor.txt", msg);
    }
    if (cff && *cff) {
        snprintf(doc, sizeof doc, "%s/Documents", cff);
        husk_qemu_write_marker(doc, "husk-qemu-ctor.txt", msg);
    }
    if (tmp && *tmp) {
        husk_qemu_write_marker(tmp, "husk-qemu-ctor.txt", msg);
    }
}


/*
 * Provide pipe2 for iOS systems where libc does not export it.
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

/* TCG's own W^X toggle. pthread_jit_write_protect_np() is marked unavailable in
 * the iOS SDK -- the symbol exists but the header refuses it -- so QEMU pokes
 * the APRR registers through the comm page instead. This file is compiled
 * inside QEMU's tcg/ directory, so the same header is the right one to use, and
 * using anything else would risk testing a different mechanism from the one the
 * emulator will actually run on. */
#include "tcg/tcg-apple-jit.h"

/* csops lives in libsystem; declare locally rather than pulling private headers. */
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000u
#endif

static bool husk_cs_debugged(void)
{
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return false;
    }
    return (flags & CS_DEBUGGED) != 0;
}

/*
 * TXM (Trusted Execution Monitor) arrived with iOS 26. On pre-TXM, TrollStore
 * Open-with-JIT attaches via trollstorehelper as a live debugger: CS_DEBUGGED
 * is set, but BRK is delivered as fatal EXC_BREAKPOINT (not SIGTRAP), so our
 * trap-guard never sees it. husk_brk_probe under that debugger always kills
 * the process. Never emit a BRK on pre-TXM.
 */
static bool husk_ios_is_pre_txm(void)
{
    char ver[64];
    size_t n = sizeof ver;
    if (sysctlbyname("kern.osproductversion", ver, &n, NULL, 0) != 0) {
        return true; /* fail closed: prefer legacy */
    }
    int major = 0;
    (void)sscanf(ver, "%d", &major);
    return major > 0 && major < 26;
}

/* Maximum verbosity by default: this path is nearly impossible to debug after the
 * fact on device, and every line here is printed at most a handful of times per
 * session. Goes to os_log (visible in Console.app) and stderr both. */
static double husk_now_ms(void)
{
    static double base = 0;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    double t = tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
    if (base == 0) { base = t; }
    return t - base;
}

#define HUSK_LOG(fmt, ...)                                                     \
    do {                                                                       \
        os_log(OS_LOG_DEFAULT, "[husk-jit] " fmt, ##__VA_ARGS__);              \
        fprintf(stderr, "[%9.2fms][husk-jit] " fmt "\n",                       \
                husk_now_ms(), ##__VA_ARGS__);                                 \
        fflush(stderr);                                                        \
    } while (0)

/* ------------------------------------------------------------------ symbols */
/*
 * The trap sequences live in husk-brk.S, compiled straight into this binary.
 * Husk deliberately does NOT link or dlopen Stossy11's BreakpointJIT.framework:
 * it has no stated license, and any embedded framework carrying entitlements is
 * rejected by AMFI at launch on sideloaded builds. See husk-brk.S for the
 * verification that our encoding matches theirs exactly.
 */
extern void    *husk_brk_get_jit_mapping(void *addr, size_t len);
extern void     husk_brk_jit_detach(void);
extern uint64_t husk_brk_probe(void);

/*
 * StikDebug answers brk #0x69 by writing a constant into x0. Two encodings are
 * seen in the wild:
 *
 *   0xE0000069  -- the value as written in the script
 *   0x690000E0  -- that value byte-reversed, which is what universal.js actually
 *                  produces: it sends the gdb-remote packet `P0=E0000069`, but P
 *                  takes the register in TARGET byte order, and ARM64 is little
 *                  endian. It also supplies only 4 bytes for an 8-byte register,
 *                  so the upper half keeps whatever poison was there (0xcccccccc
 *                  observed on iPhone18,1 / iOS 27).
 *
 * Matching on an exact value is therefore the wrong test. What actually
 * distinguishes "serviced" from "not serviced" is far simpler: when StikDebug is
 * absent, our own SIGTRAP handler steps over the brk and sets x0 to exactly 0.
 * So any non-zero answer means something serviced the trap.
 */
#define HUSK_PROBE_MAGIC    0xE0000069ull
#define HUSK_PROBE_MAGIC_LE 0x690000E0ull

static atomic_bool           g_jit_available;
static atomic_uint_least64_t g_alloc_counter;

/* ------------------------------------------------------- unserviced-trap guard */
/*
 * Set for exactly the duration of the BreakGetJITMapping call. If StikDebug is
 * not there to service the brk, the trap is a real SIGTRAP that would otherwise
 * kill the process outright -- there is no "call returned an error" to recover
 * from. The handler below turns that into a NULL return, which the allocation
 * path already handles.
 */
static _Thread_local bool g_expecting_jit_trap;

static struct sigaction g_prev_sigtrap;
static struct sigaction g_prev_sigbus;

static void husk_trap_handler(int sig, siginfo_t *info, void *ctx)
{
    (void)info;
    if (g_expecting_jit_trap && ctx != NULL) {
        ucontext_t *uc = (ucontext_t *)ctx;
        /* Step over the brk and report failure in x0, exactly as the
         * StikDebug-serviced path would have written a result there. */
        uc->uc_mcontext->__ss.__pc += 4;
        uc->uc_mcontext->__ss.__x[0] = 0;
        return;
    }

    /* Not ours: restore and re-raise so a genuine breakpoint or bus error is
     * not silently swallowed. */
    struct sigaction *prev = (sig == SIGTRAP) ? &g_prev_sigtrap : &g_prev_sigbus;
    sigaction(sig, prev, NULL);
    raise(sig);
}

void husk_ios_jit_install_trap_handler(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_flags = SA_SIGINFO;
    sa.sa_sigaction = husk_trap_handler;
    sigemptyset(&sa.sa_mask);

    if (sigaction(SIGTRAP, &sa, &g_prev_sigtrap) != 0) {
        HUSK_LOG("sigaction(SIGTRAP) failed: %s", strerror(errno));
    }
    if (sigaction(SIGBUS, &sa, &g_prev_sigbus) != 0) {
        HUSK_LOG("sigaction(SIGBUS) failed: %s", strerror(errno));
    }
    HUSK_LOG("trap guard installed (SIGTRAP, SIGBUS)");
}

/* ---------------------------------------------------------------- footprint */
/*
 * phys_footprint is the figure jetsam judges us on, so it is the one worth
 * logging around every large allocation. An iOS app with the
 * increased-memory-limit entitlement still dies silently when this crosses the
 * device's cap, and a silent kill with no crash log is otherwise very hard to
 * tell apart from any other sudden death.
 */
void husk_ios_jit_log_footprint(const char *tag)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count)
        != KERN_SUCCESS) {
        HUSK_LOG("footprint[%s]: task_info failed", tag ? tag : "");
        return;
    }
    /*
     * os_proc_available_memory() is the number that actually matters: how much
     * more this process may allocate before jetsam kills it. phys_footprint alone
     * says how much we have used but not how close to the edge that is, and the
     * limit varies by device and by whether the increased-memory-limit entitlement
     * is honoured. A jetsam kill is a SIGKILL -- no handler runs and the log simply
     * stops -- so the only way to see it coming is to watch this fall.
     */
    size_t avail = os_proc_available_memory();

    HUSK_LOG("footprint[%s]: phys=%.1f MiB  resident=%.1f MiB  "
             "available-before-jetsam=%.1f MiB",
             tag ? tag : "",
             info.phys_footprint / (1024.0 * 1024.0),
             info.resident_size  / (1024.0 * 1024.0),
             avail / (1024.0 * 1024.0));
}

size_t husk_ios_available_memory(void)
{
    return os_proc_available_memory();
}

/* ---------------------------------------------------------------- self-test */
/*
 * The decisive check. StikDebug can hand back an address, and vm_remap can
 * succeed, while the pages were never actually prepared -- `_M,rx` allocating
 * without prepare_memory_region walking each page looks identical from here.
 * In that case nothing goes wrong until TCG branches into generated code, and
 * the app dies somewhere deep in the emulator with no useful context.
 *
 * So: write a two-instruction function through the RW alias, then CALL it
 * through the RX alias. If JIT works at all, this returns 42.
 */
static bool husk_jit_selftest(const HuskDualMapping *m, bool allow_execute)
{
    /* movz w0, #42  ;  ret */
    static const uint32_t kCode[2] = { 0x52800540u, 0xD65F03C0u };

    if (m->rw_addr == NULL || m->rx_addr == NULL) {
        return false;
    }

    HUSK_LOG("selftest: writing %zu bytes through RW alias %p", sizeof(kCode),
             (void *)m->rw_addr);
    memcpy(m->rw_addr, kCode, sizeof(kCode));

    /* Flush the write through to the RX view before executing it. */
    sys_icache_invalidate(m->rx_addr, sizeof(kCode));
    HUSK_LOG("selftest: icache invalidated on RX alias %p", (void *)m->rx_addr);

    /* Read back through RX to confirm the two aliases really share pages. */
    uint32_t readback[2];
    memcpy(readback, m->rx_addr, sizeof(readback));
    if (readback[0] != kCode[0] || readback[1] != kCode[1]) {
        HUSK_LOG("selftest: FAIL -- RX alias does not reflect RW writes "
                 "(read 0x%08x 0x%08x, expected 0x%08x 0x%08x). The two mappings "
                 "are not backed by the same pages.",
                 readback[0], readback[1], kCode[0], kCode[1]);
        return false;
    }
    HUSK_LOG("selftest: RX alias reflects RW writes (0x%08x 0x%08x) -- aliasing OK",
             readback[0], readback[1]);

    /*
     * Under TrollStore Open-with-JIT the process is traced by trollstorehelper.
     * Calling into freshly minted RX pages during first-layout prewarm has been
     * observed to fault; aliasing + vm_region executable is enough to claim the
     * region. Defer in-process execute until allow_execute (post first frame /
     * TXM StikDebug path).
     */
    if (!allow_execute) {
        HUSK_LOG("selftest: PASS (alias-only; execute deferred -- safe under "
                 "TrollStore Open-with-JIT / first-layout prewarm)");
        return true;
    }

    HUSK_LOG("selftest: CALLING generated code at %p ...", (void *)m->rx_addr);
    int (*fn)(void) = (int (*)(void))(void *)m->rx_addr;
    int result = fn();

    if (result != 42) {
        HUSK_LOG("selftest: FAIL -- generated code ran but returned %d, expected 42",
                 result);
        return false;
    }
    HUSK_LOG("selftest: PASS -- executed generated code from the RX alias, got 42. "
             "JIT is genuinely live.");
    return true;
}

/* ------------------------------------------------------------- allocation */

static bool husk_page_is_executable(void *p);

/*
 * Husk: take the JIT region early, before anything slow happens.
 *
 * Two backends:
 *
 *   1. StikDebug trap servicer (TXM / iOS 26+): brk RPC -> RX pages from the
 *      debugger, then a local RW vm_remap alias.
 *   2. Legacy debugger JIT (pre-TXM, CS_DEBUGGED set by TrollStore enable-jit
 *      or a real debugger): plain anonymous RX + RW mirror via vm_remap -- the
 *      same shape UTM / Dolphin / PPSSPP use. MAP_JIT is optional and usually
 *      unavailable without dynamic-codesigning (banned on A12+ iOS 15).
 *
 * StikDebug does not stay attached indefinitely, so claim once up front.
 */

static HuskDualMapping husk_ios_jit_allocate_stikdebug(size_t bytes);
static HuskDualMapping husk_ios_jit_allocate_legacy(size_t bytes);
static HuskDualMapping husk_ios_jit_allocate_real(size_t bytes);

static HuskDualMapping husk_prewarmed;
static bool husk_prewarm_done;
static atomic_int g_mapjit_cached;          /* 0 unknown, 1 yes, -1 no */
static atomic_int g_mapjit_cached_debugged; /* -1 unknown, 0/1 last CS_DEBUGGED */

HUSK_EXPORT void husk_ios_jit_invalidate_probe_cache(void)
{
    atomic_store(&g_mapjit_cached, 0);
    atomic_store(&g_mapjit_cached_debugged, -1);
    HUSK_LOG("probe cache invalidated (re-check after CS_DEBUGGED change)");
}

HUSK_EXPORT bool husk_ios_jit_prewarm(size_t bytes)
{
    if (husk_prewarm_done) {
        return husk_prewarmed.rw_addr != NULL;
    }
    husk_prewarm_done = true;
    husk_prewarmed = husk_ios_jit_allocate_real(bytes);
    fprintf(stderr, "[husk-jit] prewarm %s: %zu bytes\n",
            husk_prewarmed.rw_addr ? "OK" : "FAILED", bytes);
    return husk_prewarmed.rw_addr != NULL;
}

HuskDualMapping husk_ios_jit_allocate(size_t bytes)
{
    /*
     * Hand back the prewarmed region when it is big enough. QEMU asks for
     * exactly tb-size, which is what prewarm was given, so this is the normal
     * path -- the fallback below only runs if prewarm never happened.
     */
    if (husk_prewarmed.rw_addr && husk_prewarmed.size >= bytes) {
        fprintf(stderr, "[husk-jit] using the prewarmed region (%zu bytes)\n",
                husk_prewarmed.size);
        return husk_prewarmed;
    }
    /*
     * A failed prewarm used to refuse every later attempt ("not trapping
     * again"). That was correct for unanswered StikDebug brks that freeze the
     * process, but wrong once CS_DEBUGGED arrives afterwards and the legacy
     * dual-map path becomes usable. Retry the full allocator; the StikDebug
     * probe is guarded and returns 0 quickly when nothing services it.
     */
    if (husk_prewarm_done && husk_prewarmed.rw_addr == NULL) {
        fprintf(stderr, "[husk-jit] prewarm failed earlier; retrying allocate "
                        "(legacy path may work now that CS_DEBUGGED is set)\n");
        HuskDualMapping again = husk_ios_jit_allocate_real(bytes);
        if (again.rw_addr) {
            husk_prewarmed = again;
        }
        return again;
    }
    return husk_ios_jit_allocate_real(bytes);
}

static HuskDualMapping husk_ios_jit_allocate_real(size_t bytes)
{
    HuskDualMapping region = { NULL, NULL, 0 };
    const bool pre_txm = husk_ios_is_pre_txm();
    const bool debugged = husk_cs_debugged();

    /*
     * Pre-TXM (iOS 15 TrollStore Open-with-JIT): CS_DEBUGGED is set by
     * trollstorehelper. Emitting husk_brk_probe() under that live debugger is
     * fatal EXC_BREAKPOINT / brk 105 -- SIGTRAP handlers never run. Always take
     * the UTM-style legacy dual-map; never BRK.
     */
    if (pre_txm || debugged) {
        HUSK_LOG("JIT backend select: legacy dual-map (pre_txm=%d CS_DEBUGGED=%d; "
                 "skipping StikDebug BRK probe)",
                 pre_txm ? 1 : 0, debugged ? 1 : 0);
        region = husk_ios_jit_allocate_legacy(bytes);
        if (region.rw_addr != NULL) {
            HUSK_LOG("JIT backend selected: legacy PASS");
            return region;
        }
        HUSK_LOG("JIT backend: legacy FAIL under CS_DEBUGGED/pre-TXM");
        if (pre_txm) {
            HUSK_LOG("no JIT backend produced executable memory (%zu bytes). On "
                     "iOS 15, use TrollStore → Open with JIT so CS_DEBUGGED is "
                     "set, then retry. Do not rely on apple-magnifier://enable-jit "
                     "if it opens Magnifier/Helper without attaching.",
                     bytes);
            return region;
        }
        /* TXM + CS_DEBUGGED but legacy refused: fall through to StikDebug. */
        HUSK_LOG("TXM device with CS_DEBUGGED: legacy unavailable; trying StikDebug");
    }

    HUSK_LOG("JIT backend select: StikDebug trap path");
    region = husk_ios_jit_allocate_stikdebug(bytes);
    if (region.rw_addr != NULL) {
        HUSK_LOG("JIT backend selected: StikDebug PASS");
        return region;
    }

    if (!pre_txm && !debugged) {
        HUSK_LOG("StikDebug path unavailable; trying legacy CS_DEBUGGED dual-map");
        region = husk_ios_jit_allocate_legacy(bytes);
        if (region.rw_addr != NULL) {
            HUSK_LOG("JIT backend selected: legacy PASS (fallback)");
            return region;
        }
    }

    HUSK_LOG("no JIT backend produced executable memory (%zu bytes). On iOS 15 "
             "pre-TXM, enable JIT with TrollStore Open with JIT so CS_DEBUGGED "
             "is set, then retry. On TXM, attach StikDebug with the Universal "
             "JIT script.",
             bytes);
    return region;
}

/*
 * Mirror an RX (or RWX) region into a writable alias. QEMU emits through RW and
 * executes through RX; tcg_splitwx_diff is rx - rw.
 */
static bool husk_dual_map_from_rx(void *rx, size_t bytes, HuskDualMapping *out)
{
    vm_address_t rw = 0;
    vm_prot_t cur_prot = VM_PROT_NONE, max_prot = VM_PROT_NONE;
    kern_return_t kr = vm_remap(mach_task_self(), &rw, (vm_size_t)bytes,
                                /*mask=*/0, VM_FLAGS_ANYWHERE,
                                mach_task_self(), (vm_address_t)rx,
                                /*copy=*/FALSE, &cur_prot, &max_prot,
                                VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        HUSK_LOG("vm_remap failed for rx=%p size=%zu: %d (%s)",
                 rx, bytes, (int)kr, mach_error_string(kr));
        return false;
    }

    kr = vm_protect(mach_task_self(), rw, (vm_size_t)bytes, /*set_maximum=*/FALSE,
                    VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        HUSK_LOG("vm_protect(RW) failed for rw=%p size=%zu: %d (%s)",
                 (void *)rw, bytes, (int)kr, mach_error_string(kr));
        vm_deallocate(mach_task_self(), rw, (vm_size_t)bytes);
        return false;
    }

    out->rw_addr = (uint8_t *)rw;
    out->rx_addr = (uint8_t *)rx;
    out->size    = bytes;
    return true;
}

/*
 * Pre-TXM legacy path: with CS_DEBUGGED set, anonymous pages can be made
 * executable without dynamic-codesigning / MAP_JIT. Prefer plain RX + RW
 * mirror (UTM "bulletproof JIT"); fall back to MAP_JIT; finally RW then
 * mprotect RX.
 *
 * Execute self-test runs ONLY when CS_DEBUGGED is set -- otherwise an unblessed
 * execute is a process-killing SIGKILL on some pre-TXM devices, not a catchable
 * fault.
 */
static HuskDualMapping husk_ios_jit_allocate_legacy(size_t bytes)
{
    HuskDualMapping region = { NULL, NULL, 0 };
    const size_t page = 16384;
    bytes = (bytes + page - 1) & ~(page - 1);

    if (!husk_cs_debugged()) {
        HUSK_LOG("legacy JIT: CS_DEBUGGED clear -- refusing to build/execute a "
                 "probe (would risk AMFI SIGKILL). Ask TrollStore to enable-jit "
                 "first.");
        return region;
    }

    struct {
        int prot;
        int flags;
        bool mprotect_rx;
        const char *name;
    } attempts[] = {
        { PROT_READ | PROT_EXEC,              0,       false, "plain-RX" },
        { PROT_READ | PROT_WRITE | PROT_EXEC, MAP_JIT, false, "MAP_JIT" },
        { PROT_READ | PROT_WRITE,             0,       true,  "RW+mprotect-RX" },
    };

    for (size_t i = 0; i < sizeof(attempts) / sizeof(attempts[0]); i++) {
        void *rx = mmap(NULL, bytes, attempts[i].prot,
                        MAP_PRIVATE | MAP_ANON | attempts[i].flags, -1, 0);
        if (rx == MAP_FAILED) {
            HUSK_LOG("legacy JIT %s: mmap failed (%s)",
                     attempts[i].name, strerror(errno));
            continue;
        }

        if (attempts[i].mprotect_rx) {
            if (mprotect(rx, bytes, PROT_READ | PROT_EXEC) != 0) {
                HUSK_LOG("legacy JIT %s: mprotect(RX) failed (%s)",
                         attempts[i].name, strerror(errno));
                munmap(rx, bytes);
                continue;
            }
        }

        if (!husk_page_is_executable(rx)) {
            HUSK_LOG("legacy JIT %s: kernel did not grant execute on %p",
                     attempts[i].name, rx);
            munmap(rx, bytes);
            continue;
        }

        if (!husk_dual_map_from_rx(rx, bytes, &region)) {
            munmap(rx, bytes);
            region.rw_addr = region.rx_addr = NULL;
            region.size = 0;
            continue;
        }

        HUSK_LOG("legacy JIT %s: dual mapping rw=%p rx=%p size=%zu diff=%+lld",
                 attempts[i].name, (void *)region.rw_addr, (void *)region.rx_addr,
                 region.size, (long long)(region.rx_addr - region.rw_addr));
        husk_ios_jit_log_footprint("after-legacy-jit-alloc");

        /* Alias-only: never execute under possible trollstorehelper trace. */
        if (!husk_jit_selftest(&region, /*allow_execute=*/false)) {
            HUSK_LOG("legacy JIT %s: selftest FAILED; releasing", attempts[i].name);
            husk_ios_jit_release(&region);
            continue;
        }

        atomic_store(&g_jit_available, true);
        HUSK_LOG("legacy JIT %s: PASS -- executable dual-map live under CS_DEBUGGED",
                 attempts[i].name);
        return region;
    }

    return region;
}

static HuskDualMapping husk_ios_jit_allocate_stikdebug(size_t bytes)
{
    HuskDualMapping region = { NULL, NULL, 0 };
    uint64_t n = atomic_fetch_add(&g_alloc_counter, 1) + 1;

    /* Cheap attach probe: brk #0x69 is answered with a constant when StikDebug
     * is live, and swallowed by our trap handler as 0 when it is not. Doing this
     * first turns "no debugger" into a clean diagnostic instead of three slow
     * retries of the real request. */
    g_expecting_jit_trap = true;
    uint64_t probe = husk_brk_probe();
    g_expecting_jit_trap = false;
    if (probe == 0) {
        HUSK_LOG("#%llu: StikDebug is NOT servicing traps -- probe returned 0 "
                 "(our SIGTRAP handler stepped over an unanswered brk).",
                 (unsigned long long)n);
        return region;
    }

    uint32_t probe_lo = (uint32_t)probe;
    if (probe_lo == (uint32_t)HUSK_PROBE_MAGIC ||
        probe_lo == (uint32_t)HUSK_PROBE_MAGIC_LE) {
        HUSK_LOG("#%llu: StikDebug attach probe OK (0x%llx)",
                 (unsigned long long)n, (unsigned long long)probe);
    } else {
        HUSK_LOG("#%llu: trap was serviced but the answer is unrecognised (0x%llx). "
                 "Continuing anyway; the allocation below is the real test.",
                 (unsigned long long)n, (unsigned long long)probe);
    }

    enum { kMaxAttempts = 3 };
    void *rx = NULL;
    for (int attempt = 1; attempt <= kMaxAttempts; attempt++) {
        HUSK_LOG("#%llu: requesting execute-capable region, size=%zu (%.1f MiB), "
                 "attempt %d/%d",
                 (unsigned long long)n, bytes, (double)bytes / (1024.0 * 1024.0),
                 attempt, kMaxAttempts);

        g_expecting_jit_trap = true;
        rx = husk_brk_get_jit_mapping(NULL, bytes);
        g_expecting_jit_trap = false;

        HUSK_LOG("#%llu: BreakGetJITMapping returned %p", (unsigned long long)n, rx);
        if (rx != NULL) {
            break;
        }
        if (attempt < kMaxAttempts) {
            usleep(50 * 1000);
        }
    }

    if (rx == NULL) {
        HUSK_LOG("#%llu: StikDebug BreakGetJITMapping FAILED after %d attempts.",
                 (unsigned long long)n, kMaxAttempts);
        return region;
    }

    if (!husk_dual_map_from_rx(rx, bytes, &region)) {
        return region;
    }

    atomic_store(&g_jit_available, true);

    HUSK_LOG("#%llu: dual mapping established: rw=%p rx=%p size=%zu diff=%+lld",
             (unsigned long long)n, (void *)region.rw_addr, (void *)region.rx_addr,
             region.size, (long long)(region.rx_addr - region.rw_addr));
    husk_ios_jit_log_footprint("after-jit-alloc");

    if (!husk_jit_selftest(&region, /*allow_execute=*/true)) {
        HUSK_LOG("#%llu: SELFTEST FAILED -- the region is not usable as JIT memory. "
                 "Refusing to hand it to TCG; QEMU would crash on its first "
                 "generated block instead of failing here.",
                 (unsigned long long)n);
        husk_ios_jit_release(&region);
        return region;
    }

    return region;
}

void husk_ios_jit_release(HuskDualMapping *m)
{
    if (m == NULL) {
        return;
    }
    if (m->rw_addr != NULL) {
        vm_deallocate(mach_task_self(), (vm_address_t)m->rw_addr, (vm_size_t)m->size);
        m->rw_addr = NULL;
    }
    if (m->rx_addr != NULL) {
        vm_deallocate(mach_task_self(), (vm_address_t)m->rx_addr, (vm_size_t)m->size);
        m->rx_addr = NULL;
    }
    m->size = 0;
}

void husk_ios_jit_detach(void)
{
    HUSK_LOG("detaching debugger; RX mappings persist after this");
    g_expecting_jit_trap = true;
    husk_brk_jit_detach();
    g_expecting_jit_trap = false;
    HUSK_LOG("debugger detached");
}

bool husk_ios_jit_is_available(void)
{
    return atomic_load(&g_jit_available);
}

/* ------------------------------------------------------------- MAP_JIT / legacy probe */
/*
 * Ask the kernel what protection a page actually received.
 */
static bool husk_page_is_executable(void *p)
{
    vm_address_t addr = (vm_address_t)p;
    vm_size_t size = 0;
    natural_t depth = 0;
    vm_region_submap_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;

    kern_return_t kr = vm_region_recurse_64(mach_task_self(), &addr, &size, &depth,
                                            (vm_region_recurse_info_t)&info, &count);
    if (kr != KERN_SUCCESS) {
        HUSK_LOG("exec probe: vm_region_recurse_64 failed: %s", mach_error_string(kr));
        return false;
    }
    HUSK_LOG("exec probe: kernel granted protection 0x%x (execute %s)",
             (unsigned)info.protection,
             (info.protection & VM_PROT_EXECUTE) ? "yes" : "NO");
    return (info.protection & VM_PROT_EXECUTE) != 0;
}

/*
 * Soft probe: can this process obtain executable anonymous memory WITHOUT a
 * trap servicer?
 *
 * MAP_JIT alone is the wrong question on A12+ iOS 15 TrollStore builds: we do
 * not embed dynamic-codesigning (AMFI banned entitlement), so mmap(..., MAP_JIT)
 * returns EINVAL even after CS_DEBUGGED is set. The real pre-TXM route is plain
 * PROT_READ|PROT_EXEC (+ RW mirror), which the kernel honours once CS_DEBUGGED
 * is set by TrollStore's ptrace attach/detach.
 *
 * Soft only: mmap + vm_region. No in-process call into the page (that can
 * SIGKILL during bring-up when CS_DEBUGGED is still clear). Cache is keyed on
 * the current CS_DEBUGGED bit so a probe taken before enable-jit does not stick
 * forever after attach.
 */
bool husk_ios_jit_mapjit_works(void)
{
    int debugged_now = husk_cs_debugged() ? 1 : 0;
    int known = atomic_load(&g_mapjit_cached);
    int known_dbg = atomic_load(&g_mapjit_cached_debugged);
    if (known != 0 && known_dbg == debugged_now) {
        return known > 0;
    }

    const size_t len = 16 * 1024;   /* one iOS page */
    bool ok = false;

    /* Prefer the plain-RX path that legacy allocate uses. */
    void *p = mmap(NULL, len, PROT_READ | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p != MAP_FAILED) {
        ok = husk_page_is_executable(p);
        HUSK_LOG("legacy soft probe (plain-RX): %s (CS_DEBUGGED %s)",
                 ok ? "PASS" : "FAIL",
                 debugged_now ? "set" : "clear");
        munmap(p, len);
    } else {
        HUSK_LOG("legacy soft probe (plain-RX): mmap refused (%s)", strerror(errno));
    }

    if (!ok) {
        p = mmap(NULL, len, PROT_READ | PROT_WRITE | PROT_EXEC,
                 MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
        if (p == MAP_FAILED) {
            HUSK_LOG("MAP_JIT soft probe: mmap refused (%s)", strerror(errno));
        } else {
            ok = husk_page_is_executable(p);
            HUSK_LOG("MAP_JIT soft probe: %s", ok ? "PASS" : "FAIL");
            munmap(p, len);
        }
    }

    if (!ok && !debugged_now) {
        HUSK_LOG("no executable anonymous mapping yet; CS_DEBUGGED is clear. "
                 "On pre-TXM, TrollStore enable-jit must set it first.");
    }

    atomic_store(&g_mapjit_cached, ok ? 1 : -1);
    atomic_store(&g_mapjit_cached_debugged, debugged_now);
    return ok;
}

#else /* !iOS: keep the symbols so host builds and tests link */

void husk_ios_jit_install_trap_handler(void) {}
static HuskDualMapping husk_ios_jit_allocate_real(size_t bytes)
{
    (void)bytes;
    HuskDualMapping m = { NULL, NULL, 0 };
    return m;
}
HuskDualMapping husk_ios_jit_allocate(size_t bytes)
{
    return husk_ios_jit_allocate_real(bytes);
}
bool husk_ios_jit_prewarm(size_t bytes) { (void)bytes; return false; }
void husk_ios_jit_release(HuskDualMapping *m) { (void)m; }
void husk_ios_jit_detach(void) {}
bool husk_ios_jit_is_available(void) { return false; }
bool husk_ios_jit_mapjit_works(void) { return false; }
void husk_ios_jit_invalidate_probe_cache(void) {}
void husk_ios_jit_log_footprint(const char *tag) { (void)tag; }
size_t husk_ios_available_memory(void) { return 0; }

#endif
