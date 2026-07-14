/*
 * libbun-mte-fix.c — LD_PRELOAD shim to fix MTE/tagged-pointer crashes on Android
 *
 * PROBLEM:
 *   On Android arm64 with MTE (Memory Tagging Extension), malloc() returns
 *   pointers with a non-zero top byte (e.g., 0xb4). When Bun's FFI passes
 *   these tagged pointers to free(), scudo crashes (SIGABRT or SEGFAULT).
 *
 *   MTE is HARDWARE-ACTIVE: the CPU checks tags on every memory access.
 *   MEMTAG_OPTIONS=off doesn't disable it (force-enabled via ELF notes
 *   or kernel config).
 *
 *   CRITICAL: Bun's FFI uses dlopen() + dlsym() to get function pointers
 *   from libc.so. dlsym() with a specific library handle BYPASSES
 *   LD_PRELOAD — so intercepting malloc/free symbols is NOT enough.
 *   We must ALSO intercept dlsym() to redirect malloc/free lookups
 *   to our wrappers.
 *
 * SOLUTION:
 *   1. Intercept dlsym(): when Bun's FFI asks for "malloc"/"free"/etc.,
 *      return our wrapper functions instead of libc's direct functions.
 *   2. In our malloc wrapper: call real malloc, strip tag, store original
 *      tagged pointer in a side table, return untagged to Bun.
 *   3. In our free wrapper: look up original tag from side table,
 *      re-apply tag, call real free with the correct tagged pointer.
 *
 *   This ensures:
 *   - Bun's JS code sees untagged pointers (no precision issues)
 *   - scudo's free() receives the exact tagged pointer it expects
 *   - MTE hardware checks pass (correct tag on memory accesses)
 *
 * BUILD:
 *   clang -shared -fPIC -O2 -o libbun-mte-fix.so libbun-mte-fix.c -ldl
 *
 * USAGE:
 *   LD_PRELOAD=/path/to/libbun-mte-fix.so bun ...
 *
 * License: MIT
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

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

/* ─── Tag manipulation ──────────────────────────────────────────── */
#define TAG_MASK  0xFF00000000000000ULL
#define ADDR_MASK 0x00FFFFFFFFFFFFFFULL

static inline void *untag_pointer(void *p) {
    return (void *)((uintptr_t)p & ADDR_MASK);
}

static inline uintptr_t get_tag(void *p) {
    return (uintptr_t)p & TAG_MASK;
}

/* ─── Side table: untagged addr → original tagged pointer ──────── */
#define TABLE_BITS 16
#define TABLE_SIZE (1 << TABLE_BITS)
#define TABLE_MASK (TABLE_SIZE - 1)

typedef struct {
    _Atomic(uintptr_t) untagged;
    uintptr_t tagged;
} entry_t;

static entry_t side_table[TABLE_SIZE] = {{0, 0}};
static pthread_mutex_t table_lock = PTHREAD_MUTEX_INITIALIZER;

static inline size_t hash_addr(uintptr_t untagged) {
    uintptr_t h = untagged;
    h ^= h >> 16;
    h ^= h >> 32;
    h *= 0x9E3779B97F4A7C15ULL;
    h >>= (64 - TABLE_BITS);
    return (size_t)h;
}

static void table_insert(uintptr_t untagged, uintptr_t tagged) {
    if (untagged == 0) return;
    size_t idx = hash_addr(untagged);
    pthread_mutex_lock(&table_lock);
    for (size_t i = 0; i < TABLE_SIZE; i++) {
        size_t probe = (idx + i) & TABLE_MASK;
        uintptr_t existing = atomic_load_explicit(&side_table[probe].untagged,
                                                   memory_order_relaxed);
        if (existing == 0 || existing == untagged) {
            side_table[probe].untagged = untagged;
            side_table[probe].tagged = tagged;
            pthread_mutex_unlock(&table_lock);
            return;
        }
    }
    debug_log("[mte-fix] WARNING: side table full\n");
    side_table[0].untagged = untagged;
    side_table[0].tagged = tagged;
    pthread_mutex_unlock(&table_lock);
}

static uintptr_t table_lookup(uintptr_t untagged) {
    if (untagged == 0) return 0;
    size_t idx = hash_addr(untagged);
    for (size_t i = 0; i < TABLE_SIZE; i++) {
        size_t probe = (idx + i) & TABLE_MASK;
        uintptr_t existing = atomic_load_explicit(&side_table[probe].untagged,
                                                   memory_order_relaxed);
        if (existing == 0) return 0;
        if (existing == untagged) return side_table[probe].tagged;
    }
    return 0;
}

static void table_remove(uintptr_t untagged) {
    if (untagged == 0) return;
    size_t idx = hash_addr(untagged);
    pthread_mutex_lock(&table_lock);
    for (size_t i = 0; i < TABLE_SIZE; i++) {
        size_t probe = (idx + i) & TABLE_MASK;
        uintptr_t existing = side_table[probe].untagged;
        if (existing == 0) break;
        if (existing == untagged) {
            side_table[probe].untagged = 0;
            side_table[probe].tagged = 0;
            size_t next = (probe + 1) & TABLE_MASK;
            while (side_table[next].untagged != 0) {
                uintptr_t re_untagged = side_table[next].untagged;
                uintptr_t re_tagged = side_table[next].tagged;
                side_table[next].untagged = 0;
                side_table[next].tagged = 0;
                size_t re_idx = hash_addr(re_untagged);
                for (size_t j = 0; j < TABLE_SIZE; j++) {
                    size_t re_probe = (re_idx + j) & TABLE_MASK;
                    if (side_table[re_probe].untagged == 0) {
                        side_table[re_probe].untagged = re_untagged;
                        side_table[re_probe].tagged = re_tagged;
                        break;
                    }
                }
                next = (next + 1) & TABLE_MASK;
            }
            break;
        }
    }
    pthread_mutex_unlock(&table_lock);
}

/* ─── Real function pointers ────────────────────────────────────── */
typedef void *(*malloc_fn)(size_t);
typedef void *(*calloc_fn)(size_t, size_t);
typedef void *(*realloc_fn)(void *, size_t);
typedef void (*free_fn)(void *);

/* NOTE: real_dlsym is NOT a function pointer — we call __loader_dlsym
 * directly because it has a different signature (3 args vs 2 args). */

static malloc_fn real_malloc = NULL;
static calloc_fn real_calloc = NULL;
static realloc_fn real_realloc = NULL;
static free_fn real_free = NULL;

/* On Bionic (Android), the dynamic linker exports __loader_dlsym which
 * is the underlying implementation of dlsym. It takes 3 arguments:
 *   handle, symbol, caller_addr
 * We call it directly to bypass our own dlsym interception. */
extern void *__loader_dlsym(void *handle, const char *symbol, void *caller_addr);

/* Wrapper to call __loader_dlsym with the right 3rd argument */
static void *call_real_dlsym(void *handle, const char *symbol) {
    return __loader_dlsym(handle, symbol, __builtin_return_address(0));
}

static void init_real(void) {
    if (real_malloc) return;

    /* Use __loader_dlsym to get real function pointers without going
     * through our intercepted dlsym. */
    real_malloc = (malloc_fn)call_real_dlsym(RTLD_NEXT, "malloc");
    real_calloc = (calloc_fn)call_real_dlsym(RTLD_NEXT, "calloc");
    real_realloc = (realloc_fn)call_real_dlsym(RTLD_NEXT, "realloc");
    real_free = (free_fn)call_real_dlsym(RTLD_NEXT, "free");

    if (!real_malloc || !real_free) {
        fprintf(stderr, "[mte-fix] FATAL: cannot resolve real malloc/free\n");
        _exit(1);
    }

    debug_log("[mte-fix] initialized: real_malloc=%p real_free=%p\n",
              (void*)real_malloc, (void*)real_free);
}

/* ─── Our wrapper functions (returned by dlsym interception) ────── */

static void *our_malloc(size_t size) {
    if (!real_malloc) init_real();
    void *tagged = real_malloc(size);
    if (!tagged) return NULL;

    uintptr_t tag = get_tag(tagged);
    if (tag == 0) return tagged;

    void *untagged = untag_pointer(tagged);
    table_insert((uintptr_t)untagged, (uintptr_t)tagged);

    debug_log("[mte-fix] malloc(%zu) = %p → %p (tag 0x%02x)\n",
              size, tagged, untagged, (unsigned)(tag >> 56));
    return untagged;
}

static void *our_calloc(size_t nmemb, size_t size) {
    if (!real_malloc) init_real();
    void *tagged = real_calloc(nmemb, size);
    if (!tagged) return NULL;

    uintptr_t tag = get_tag(tagged);
    if (tag == 0) return tagged;

    void *untagged = untag_pointer(tagged);
    table_insert((uintptr_t)untagged, (uintptr_t)tagged);

    debug_log("[mte-fix] calloc(%zu, %zu) = %p → %p (tag 0x%02x)\n",
              nmemb, size, tagged, untagged, (unsigned)(tag >> 56));
    return untagged;
}

static void *our_realloc(void *ptr, size_t size) {
    if (!real_malloc) init_real();

    if (ptr == NULL) return our_malloc(size);

    uintptr_t untagged_in = (uintptr_t)untag_pointer(ptr);
    uintptr_t tagged_in = table_lookup(untagged_in);
    if (tagged_in == 0) tagged_in = untagged_in;

    table_remove(untagged_in);

    void *tagged_out = real_realloc((void *)tagged_in, size);
    if (!tagged_out) return NULL;

    uintptr_t tag_out = get_tag(tagged_out);
    if (tag_out == 0) return tagged_out;

    void *untagged_out = untag_pointer(tagged_out);
    table_insert((uintptr_t)untagged_out, (uintptr_t)tagged_out);

    debug_log("[mte-fix] realloc(%p, %zu) = %p → %p\n",
              ptr, size, tagged_out, untagged_out);
    return untagged_out;
}

static void our_free(void *ptr) {
    if (!real_malloc) init_real();

    if (ptr == NULL) {
        real_free(ptr);
        return;
    }

    uintptr_t untagged = (uintptr_t)untag_pointer(ptr);
    uintptr_t tagged = table_lookup(untagged);

    if (tagged != 0) {
        debug_log("[mte-fix] free(%p) → using tagged %p\n", ptr, (void *)tagged);
        real_free((void *)tagged);
        table_remove(untagged);
    } else {
        /* Not in side table — this pointer was either:
         * 1. Allocated before our shim was loaded
         * 2. Allocated by a function we don't intercept
         *
         * If the pointer has a tag (top byte != 0), pass it directly
         * to real_free (scudo expects the tagged pointer).
         * If the pointer is untagged (top byte == 0), we can't recover
         * the tag — this will likely crash, but there's nothing we
         * can do. */
        uintptr_t tag = get_tag(ptr);
        if (tag != 0) {
            debug_log("[mte-fix] free(%p) → not in table, has tag, passing directly\n", ptr);
            real_free(ptr);
        } else {
            debug_log("[mte-fix] free(%p) → not in table, untagged — trying direct free\n", ptr);
            real_free(ptr);
        }
    }
}

/* ─── Interception: malloc/calloc/realloc/free (global symbol) ──── */
/* These intercept calls from shared libraries (like libopentui.so)
 * that go through the global symbol table (PLT/GOT). */

void *malloc(size_t size) {
    return our_malloc(size);
}

void *calloc(size_t nmemb, size_t size) {
    return our_calloc(nmemb, size);
}

void *realloc(void *ptr, size_t size) {
    return our_realloc(ptr, size);
}

void free(void *ptr) {
    our_free(ptr);
}

/* ─── Interception: dlsym (THE KEY FIX) ─────────────────────────── */
/* Bun's FFI uses dlopen() + dlsym() to get function pointers from
 * libc.so. dlsym() with a specific library handle bypasses LD_PRELOAD,
 * so our malloc/free interceptions above are NOT called.
 *
 * By intercepting dlsym() itself, we can redirect "malloc"/"free"
 * lookups to our wrapper functions, ensuring that Bun's FFI calls
 * go through our tag-stripping/re-applying logic. */

void *dlsym(void *handle, const char *symbol) {
    if (!real_malloc) init_real();

    /* Redirect memory allocation functions to our wrappers */
    if (symbol) {
        if (strcmp(symbol, "malloc") == 0) {
            debug_log("[mte-fix] dlsym(%p, \"malloc\") → redirected to our_malloc\n", handle);
            return (void *)our_malloc;
        }
        if (strcmp(symbol, "calloc") == 0) {
            debug_log("[mte-fix] dlsym(%p, \"calloc\") → redirected to our_calloc\n", handle);
            return (void *)our_calloc;
        }
        if (strcmp(symbol, "realloc") == 0) {
            debug_log("[mte-fix] dlsym(%p, \"realloc\") → redirected to our_realloc\n", handle);
            return (void *)our_realloc;
        }
        if (strcmp(symbol, "free") == 0) {
            debug_log("[mte-fix] dlsym(%p, \"free\") → redirected to our_free\n", handle);
            return (void *)our_free;
        }
    }

    return call_real_dlsym(handle, symbol);
}

/* ─── Constructor ───────────────────────────────────────────────── */
__attribute__((constructor))
static void init(void) {
    init_real();
    debug_log("[mte-fix] shim loaded (with dlsym interception)\n");
    debug_log("[mte-fix] table size: %d entries\n", TABLE_SIZE);
}
