/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Husk -- iOS dual-mapped JIT memory for QEMU's TCG.
 *
 * Derived from AetherPS4-iOS's src/core/ios/ios_jit_allocator.cpp
 * (shadPS4 Emulator Project, GPL-2.0-or-later), ported from C++ to C and
 * reshaped to hand QEMU's tcg/region.c a split-W^X code buffer.
 *
 * ---------------------------------------------------------------------------
 * Why this file exists
 * ---------------------------------------------------------------------------
 * On TXM devices (iOS 26+ on A14+/A15+ class silicon) an app cannot map RWX or
 * mprotect anything to PROT_EXEC; executable memory must come from a trap
 * servicer (StikDebug). On pre-TXM (iOS 15 TrollStore, CS_DEBUGGED set by
 * enable-jit) the classic UTM dual-map works: plain RX + RW vm_remap, no
 * dynamic-codesigning / MAP_JIT required.
 *
 * StikDebug provides the TXM path over a breakpoint-based RPC
 * (BreakpointJIT.framework):
 *
 *     BreakGetJITMapping(NULL, size)   ->  brk #0xf00d, x16 = 1
 *
 * StikDebug catches the trap, issues debugserver `_M<size>,rx` to allocate an
 * executable region inside us, then writes one byte through the debugger into
 * every 16 KiB page of it (`M<addr>,1:69`) -- which is what actually makes the
 * pages usable -- and finally stuffs the address back into x0 before resuming.
 *
 * We then make our own writable alias of the same physical pages with vm_remap.
 * QEMU emits code through the RW alias and executes through the RX alias;
 * tcg/region.c already understands exactly this shape via tcg_splitwx_diff.
 *
 * ---------------------------------------------------------------------------
 * The one-shot rule
 * ---------------------------------------------------------------------------
 * After setup the app calls BreakJITDetach() and StikDebug goes away. From then
 * on a BreakGetJITMapping trap is NOT serviced -- and an unserviced `brk` is a
 * fatal SIGTRAP, not a failed call. StikDebug can also be killed mid-session by
 * iOS's background wake-rate limiter.
 *
 * So: allocate ONCE, up front, at a size that is provably sufficient for the
 * whole session, and never plan on getting a second region. For QEMU this is a
 * natural fit -- TCG sizes its translation buffer once at init from
 * `-accel tcg,tb-size=N` and flushes rather than grows when it fills.
 *
 * husk_ios_jit_install_trap_handler() must be called early in app startup so
 * that a missed trap degrades into a NULL return instead of killing the process.
 */

#ifndef HUSK_IOS_JIT_H
#define HUSK_IOS_JIT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* See husk-display.h for why this is necessary. */
#define HUSK_EXPORT __attribute__((visibility("default")))

typedef struct HuskDualMapping {
    uint8_t *rw_addr;   /* writable alias  -- emit code here            */
    uint8_t *rx_addr;   /* executable alias -- branch here              */
    size_t   size;
} HuskDualMapping;

/*
 * Install SIGTRAP/SIGBUS handlers that skip an unserviced BreakpointJIT trap
 * (pc += 4, x0 = 0) instead of letting it kill the process. Call once, early,
 * before any JIT allocation. Safe to call when StikDebug is absent.
 */
HUSK_EXPORT void husk_ios_jit_install_trap_handler(void);

/*
 * Allocate one dual-mapped region of `bytes`. Returns a mapping whose rw_addr is
 * NULL on failure. `bytes` is rounded up to a 16 KiB page multiple by the caller's
 * contract -- StikDebug prepares whole pages.
 */
HuskDualMapping husk_ios_jit_allocate(size_t bytes);

/*
 * Claim the JIT region now, at app launch, and hold it until QEMU asks.
 * StikDebug does not stay attached forever, and a first run spends a minute
 * downloading the guest before QEMU starts -- by which time the debugger has
 * let go and no executable memory can be had at all. Pass the same size QEMU
 * will ask for (tb-size).
 */
HUSK_EXPORT bool husk_ios_jit_prewarm(size_t bytes);

/* Release a mapping obtained from husk_ios_jit_allocate(). */
void husk_ios_jit_release(HuskDualMapping *m);

/*
 * Tell StikDebug to detach. RX mappings already obtained stay valid and
 * executable; no further allocation is possible afterwards.
 */
HUSK_EXPORT void husk_ios_jit_detach(void);

/* True once a successful allocation has happened -- i.e. JIT is genuinely live. */
HUSK_EXPORT bool husk_ios_jit_is_available(void);

/*
 * Soft probe: can this process obtain executable anonymous memory WITHOUT a
 * StikDebug trap servicer? Tries plain PROT_READ|PROT_EXEC first (the pre-TXM
 * CS_DEBUGGED path used by UTM), then MAP_JIT. Soft only -- mmap + vm_region,
 * never an in-process call into the page (that can AMFI-SIGKILL during bring-up
 * when CS_DEBUGGED is still clear). Cache is keyed on the current CS_DEBUGGED
 * bit; call husk_ios_jit_invalidate_probe_cache() after enable-jit attaches.
 */
HUSK_EXPORT bool husk_ios_jit_mapjit_works(void);

/* Drop the soft-probe cache so the next mapjit_works() re-checks under the
 * current CS_DEBUGGED state (call after TrollStore/StikDebug attach). */
HUSK_EXPORT void husk_ios_jit_invalidate_probe_cache(void);

/*
 * When the region was made without a trap servicer (before iOS 26: TrollStore, a jailbreak, or a debugger that has let go),
 * which way: "MAP_JIT" or "plain". NULL otherwise.
 */
HUSK_EXPORT const char *husk_ios_jit_self_route(void);

/*
 * Log the process's phys_footprint -- the number jetsam actually kills on.
 * `tag` labels the call site in the log.
 */
HUSK_EXPORT void husk_ios_jit_log_footprint(const char *tag);

/*
 * Bytes this process may still allocate before jetsam kills it. Used to size the
 * guest's RAM to the device rather than to a guess.
 */
HUSK_EXPORT size_t husk_ios_available_memory(void);

#ifdef __cplusplus
}
#endif

#endif /* HUSK_IOS_JIT_H */
