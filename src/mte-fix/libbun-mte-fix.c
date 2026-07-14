/*
 * libbun-mte-fix.c — Disable Android heap tagging for Bun
 *
 * PROBLEM:
 *   Android 12+ enables heap tagging (MTE + Tagged Pointer ABI) for
 *   processes. Scudo tags malloc'd pointers with a non-zero top byte
 *   (e.g., 0xb4). Both checks are active:
 *
 *   1. SOFTWARE check (Tagged Pointer ABI):
 *      free(untagged_ptr) → SIGABRT
 *      "Pointer tag for 0x... was truncated"
 *
 *   2. HARDWARE check (MTE):
 *      free(tagged_ptr) → scudo accesses chunk header at untag(ptr)-16
 *      with untagged pointer → MTE hardware raises SEGFAULT
 *
 *   MEMTAG_OPTIONS=off doesn't work because MTE is force-enabled via
 *   ELF notes or kernel config on this device.
 *
 *   The LD_PRELOAD interception approach (intercepting malloc/free/dlsym)
 *   CANNOT fix this because the crash happens INSIDE scudo's own free()
 *   code — scudo strips the tag internally before accessing the chunk
 *   header, then MTE hardware rejects the untagged access.
 *
 * SOLUTION:
 *   Call android_mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, NONE) in a
 *   constructor that runs BEFORE scudo initializes. This disables:
 *   - MTE tag generation in malloc
 *   - Tagged Pointer ABI check in free
 *   - Hardware MTE tag checking
 *
 *   After this, malloc returns untagged pointers, free accepts untagged
 *   pointers, and no MTE hardware checks are performed.
 *
 *   We also call prctl(PR_SET_TAGGED_ADDR_CTRL, 0) to disable MTE for
 *   the current thread, as a belt-and-suspenders approach.
 *
 * BUILD:
 *   clang -shared -fPIC -O2 -o libbun-mte-fix.so libbun-mte-fix.c
 *
 * USAGE:
 *   LD_PRELOAD=/path/to/libbun-mte-fix.so bun ...
 *
 * License: MIT
 */

#define _GNU_SOURCE
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/prctl.h>

/* ─── Bionic mallopt constants ──────────────────────────────────── */
/* These are defined in Bionic's malloc.h but may not be in the NDK
 * headers we're building with. Define them ourselves. */

/* android_mallopt function signature:
 *   int android_mallopt(int opcode, void *arg, size_t arg_size);
 */
extern int android_mallopt(int opcode, void *arg, size_t arg_size);

/* Opcode to set heap tagging level */
#define M_BIONIC_SET_HEAP_TAGGING_LEVEL 4

/* Tagging levels */
#define M_HEAP_TAGGING_LEVEL_NONE 0
#define M_HEAP_TAGGING_LEVEL_TBI  1

/* ─── prctl constants for MTE ───────────────────────────────────── */
/* PR_SET_TAGGED_ADDR_CTRL allows disabling MTE for the current thread.
 * This must be called before any heap allocation for full effect, but
 * calling it in a constructor still helps by disabling MTE for future
 * memory accesses. */

#ifndef PR_SET_TAGGED_ADDR_CTRL
#define PR_SET_TAGGED_ADDR_CTRL 55
#endif

#ifndef PR_TAGGED_ADDR_ENABLE
#define PR_TAGGED_ADDR_ENABLE (1UL << 0)
#endif

#ifndef PR_MTE_TCF_SHIFT
#define PR_MTE_TCF_SHIFT 1
#endif

#ifndef PR_MTE_TCF_NONE
#define PR_MTE_TCF_NONE (0UL << PR_MTE_TCF_SHIFT)
#endif

#ifndef PR_MTE_TCF_MASK
#define PR_MTE_TCF_MASK (3UL << PR_MTE_TCF_SHIFT)
#endif

/* ─── Debug logging ──────────────────────────────────────────────── */
static int debug_enabled = -1;
static void debug_log(const char *fmt, ...) {
    if (debug_enabled == -1) {
        debug_enabled = getenv("BUN_MTE_FIX_DEBUG") ? 1 : 0;
    }
    if (!debug_enabled) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fflush(stderr);
}

/* ─── Constructor: runs before main(), before scudo init ────────── */
/* The constructor priority is set to 101 (high priority) to run
 * before most other library constructors. This gives us the best
 * chance of running before scudo initializes. */
__attribute__((constructor(101)))
static void init_disable_heap_tagging(void) {
    int result;
    int errors = 0;

    /* Step 1: Disable heap tagging via android_mallopt.
     * This tells scudo to NOT tag pointers and to NOT check tags in free. */
    int level = M_HEAP_TAGGING_LEVEL_NONE;
    result = android_mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL,
                              &level, sizeof(level));
    if (result != 0) {
        debug_log("[mte-fix] android_mallopt(SET_HEAP_TAGGING_LEVEL, NONE) FAILED (ret=%d)\n", result);
        errors++;
    } else {
        debug_log("[mte-fix] android_mallopt(SET_HEAP_TAGGING_LEVEL, NONE) OK\n");
    }

    /* Step 2: Disable MTE via prctl.
     * This disables hardware MTE tag checking for the current thread.
     * PR_MTE_TCF_NONE = no tag checking (not even async). */
    /* First, clear the tagged address enable bit and set TCF to NONE */
    unsigned long ctrl = 0;  /* PR_TAGGED_ADDR_ENABLE = 0, PR_MTE_TCF_NONE */
    result = prctl(PR_SET_TAGGED_ADDR_CTRL, ctrl, 0, 0, 0);
    if (result != 0) {
        debug_log("[mte-fix] prctl(PR_SET_TAGGED_ADDR_CTRL, 0) FAILED (ret=%d)\n", result);
        errors++;
    } else {
        debug_log("[mte-fix] prctl(PR_SET_TAGGED_ADDR_CTRL, 0) OK — MTE disabled\n");
    }

    /* Step 3: Also check MEMTAG_OPTIONS (in case it helps on some devices) */
    if (!getenv("MEMTAG_OPTIONS")) {
        /* Set it for good measure, though it only works at process start */
        setenv("MEMTAG_OPTIONS", "off", 1);
        debug_log("[mte-fix] set MEMTAG_OPTIONS=off\n");
    }

    if (errors == 0) {
        debug_log("[mte-fix] heap tagging disabled successfully\n");
    } else {
        debug_log("[mte-fix] WARNING: %d errors disabling heap tagging\n", errors);
        debug_log("[mte-fix] MTE may still be active — FFI crashes may persist\n");
    }
}
