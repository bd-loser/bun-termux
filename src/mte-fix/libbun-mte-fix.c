/*
 * libbun-mte-fix.c — LD_PRELOAD shim to fix MTE/tagged-pointer crashes on Android
 *
 * PROBLEM:
 *   On Android arm64 with MTE (Memory Tagging Extension) or heap tagging,
 *   malloc() returns pointers with a non-zero top byte (e.g., 0xb4).
 *   When Bun's FFI passes these tagged pointers to free(), scudo's
 *   tag check may SIGABRT.
 *
 *   This happens because:
 *   1. MEMTAG_OPTIONS=off doesn't work on some Android versions
 *   2. MTE may be force-enabled via ELF notes or kernel config
 *   3. Scudo's free() may reject tagged pointers from external callers
 *
 * SOLUTION:
 *   This shim intercepts malloc/calloc/realloc/free:
 *   - In malloc/calloc/realloc: store the tagged pointer in a side table
 *     keyed by the untagged address, then STRIP the tag before returning
 *     to the caller. This ensures JS/Bun code never sees tagged pointers.
 *   - In free: look up the original tagged pointer from the side table,
 *     re-apply the tag, and call the real free with the correct tagged
 *     pointer. This ensures scudo's free() receives the pointer it expects.
 *
 *   This approach handles ALL cases:
 *   - If FFI preserves tags: side table lookup finds the same tag (no-op)
 *   - If FFI strips tags: side table lookup restores the correct tag
 *   - If scudo requires tags: we re-apply the correct tag
 *   - If scudo accepts untagged: we still pass the tagged ptr (works either way)
 *
 * BUILD:
 *   clang -shared -fPIC -O2 -o libbun-mte-fix.so libbun-mte-fix.c -ldl
 *   (or use the build script)
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
    __builtin_va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    __builtin_va_end(ap);
    fflush(stderr);
}

/* ─── Tag manipulation ──────────────────────────────────────────── */
/* On Android arm64 with MTE, the top byte (bits 56-63) is the tag.
 * The actual address is in bits 0-55.
 *
 * MTE uses bits 56-59 (4 bits) for the tag, bits 60-63 should be 0.
 * But some Android versions use the full top byte (8 bits) for tagging.
 *
 * We handle both cases by masking the entire top byte.
 */
#define TAG_MASK  0xFF00000000000000ULL
#define ADDR_MASK 0x00FFFFFFFFFFFFFFULL

static inline void *untag_pointer(void *p) {
    return (void *)((uintptr_t)p & ADDR_MASK);
}

static inline uintptr_t get_tag(void *p) {
    return (uintptr_t)p & TAG_MASK;
}

static inline void *retag_pointer(void *untagged, uintptr_t tag) {
    return (void *)((uintptr_t)untagged | tag);
}

/* ─── Side table: untagged addr → original tagged pointer ──────── */
/* We use a hash table to map untagged addresses to their original tags.
 *
 * The table is sized for typical Bun workloads (yoga nodes, render buffers, etc.).
 * Collisions are handled by linear probing.
 *
 * Thread safety: a mutex protects insert/delete. Lookups are lock-free
 * for reads (using atomic loads), but inserts take the lock.
 */

#define TABLE_BITS 16  /* 64K entries */
#define TABLE_SIZE (1 << TABLE_BITS)
#define TABLE_MASK (TABLE_SIZE - 1)

typedef struct {
    _Atomic(uintptr_t) untagged;  /* 0 = empty, else untagged address */
    uintptr_t tagged;             /* original tagged pointer */
} entry_t;

static entry_t side_table[TABLE_SIZE] = {{0, 0}};
static pthread_mutex_t table_lock = PTHREAD_MUTEX_INITIALIZER;

/* Simple hash: take the top bits of the untagged address (they're more
 * varying than the bottom bits, which are aligned). */
static inline size_t hash_addr(uintptr_t untagged) {
    /* Mix the bits to spread allocations across the table */
    uintptr_t h = untagged;
    h ^= h >> 16;
    h ^= h >> 32;
    h *= 0x9E3779B97F4A7C15ULL;  /* golden ratio constant */
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
            side_table[probe].untagged = untagged;  /* atomic store not needed, we hold the lock */
            side_table[probe].tagged = tagged;
            pthread_mutex_unlock(&table_lock);
            return;
        }
    }

    /* Table full — this shouldn't happen in practice. Fall back to
     * overwriting the first slot (better than crashing). */
    debug_log("[mte-fix] WARNING: side table full, overwriting slot 0\n");
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
        if (existing == 0) {
            return 0;  /* not found (empty slot = end of chain) */
        }
        if (existing == untagged) {
            return side_table[probe].tagged;
        }
    }
    return 0;  /* not found (table full) */
}

static void table_remove(uintptr_t untagged) {
    if (untagged == 0) return;

    size_t idx = hash_addr(untagged);
    pthread_mutex_lock(&table_lock);

    for (size_t i = 0; i < TABLE_SIZE; i++) {
        size_t probe = (idx + i) & TABLE_MASK;
        uintptr_t existing = side_table[probe].untagged;
        if (existing == 0) {
            break;  /* not found */
        }
        if (existing == untagged) {
            /* Found — remove this entry and re-insert subsequent entries
             * to maintain the linear probing invariant. */
            side_table[probe].untagged = 0;
            side_table[probe].tagged = 0;

            /* Re-insert subsequent entries in the chain */
            size_t next = (probe + 1) & TABLE_MASK;
            while (side_table[next].untagged != 0) {
                uintptr_t re_untagged = side_table[next].untagged;
                uintptr_t re_tagged = side_table[next].tagged;
                side_table[next].untagged = 0;
                side_table[next].tagged = 0;

                /* Re-insert at the correct position */
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
typedef void *(*mmap_fn)(void *, size_t, int, int, int, off_t);
typedef void *(*aligned_alloc_fn)(size_t, size_t);
typedef int (*posix_memalign_fn)(void **, size_t, size_t);

static malloc_fn real_malloc = NULL;
static calloc_fn real_calloc = NULL;
static realloc_fn real_realloc = NULL;
static free_fn real_free = NULL;

static void init_real(void) {
    if (real_malloc) return;
    real_malloc = (malloc_fn)dlsym(RTLD_NEXT, "malloc");
    real_calloc = (calloc_fn)dlsym(RTLD_NEXT, "calloc");
    real_realloc = (realloc_fn)dlsym(RTLD_NEXT, "realloc");
    real_free = (free_fn)dlsym(RTLD_NEXT, "free");

    if (!real_malloc || !real_free) {
        /* This is a critical error — we can't function without real malloc/free */
        fprintf(stderr, "[mte-fix] FATAL: cannot resolve real malloc/free\n");
        _exit(1);
    }
}

/* ─── Interception: malloc ──────────────────────────────────────── */
void *malloc(size_t size) {
    if (!real_malloc) init_real();
    void *tagged = real_malloc(size);
    if (!tagged) return NULL;

    uintptr_t tag = get_tag(tagged);
    if (tag == 0) {
        /* Pointer is already untagged — nothing to do */
        return tagged;
    }

    void *untagged = untag_pointer(tagged);
    table_insert((uintptr_t)untagged, (uintptr_t)tagged);

    debug_log("[mte-fix] malloc(%zu) = %p → %p (tag 0x%02x)\n",
              size, tagged, untagged, (unsigned)(tag >> 56));
    return untagged;
}

/* ─── Interception: calloc ──────────────────────────────────────── */
void *calloc(size_t nmemb, size_t size) {
    if (!real_malloc) init_real();
    /* Note: we use real_calloc, not real_malloc+memset, because calloc
     * may use a different allocation path (e.g., for large allocations). */
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

/* ─── Interception: realloc ─────────────────────────────────────── */
void *realloc(void *ptr, size_t size) {
    if (!real_malloc) init_real();

    if (ptr == NULL) {
        /* realloc(NULL, size) == malloc(size) */
        return malloc(size);
    }

    /* Look up the original tagged pointer */
    uintptr_t untagged_in = (uintptr_t)untag_pointer(ptr);
    uintptr_t tagged_in = table_lookup(untagged_in);
    if (tagged_in == 0) {
        /* Not in our table — assume it was already untagged */
        tagged_in = untagged_in;
    }

    /* Remove the old entry (the old block is being freed) */
    table_remove(untagged_in);

    /* Call real realloc with the tagged pointer */
    void *tagged_out = real_realloc((void *)tagged_in, size);
    if (!tagged_out) return NULL;

    uintptr_t tag_out = get_tag(tagged_out);
    if (tag_out == 0) {
        return tagged_out;
    }

    void *untagged_out = untag_pointer(tagged_out);
    table_insert((uintptr_t)untagged_out, (uintptr_t)tagged_out);

    debug_log("[mte-fix] realloc(%p, %zu) = %p → %p (tag 0x%02x)\n",
              ptr, size, tagged_out, untagged_out, (unsigned)(tag_out >> 56));
    return untagged_out;
}

/* ─── Interception: free ────────────────────────────────────────── */
void free(void *ptr) {
    if (!real_malloc) init_real();

    if (ptr == NULL) {
        real_free(ptr);
        return;
    }

    /* Look up the original tagged pointer */
    uintptr_t untagged = (uintptr_t)untag_pointer(ptr);
    uintptr_t tagged = table_lookup(untagged);

    if (tagged != 0) {
        /* Found in side table — use the original tagged pointer */
        debug_log("[mte-fix] free(%p) → using tagged %p\n", ptr, (void *)tagged);
        real_free((void *)tagged);
        table_remove(untagged);
    } else {
        /* Not in side table — this pointer was either:
         * 1. Allocated before our shim was loaded (e.g., by Bun itself)
         * 2. Allocated by a function we don't intercept (e.g., mmap)
         * Try passing the untagged pointer to real free. If scudo accepts
         * untagged pointers, this works. If not, it'll SIGABRT (but the
         * pointer wasn't in our table anyway, so we can't help). */
        debug_log("[mte-fix] free(%p) → not in table, trying untagged %p\n",
                  ptr, (void *)untagged);
        real_free((void *)untagged);
    }
}

/* ─── Constructor: log that we're loaded ────────────────────────── */
__attribute__((constructor))
static void init(void) {
    init_real();
    debug_log("[mte-fix] shim loaded (debug mode)\n");
    debug_log("[mte-fix] table size: %d entries\n", TABLE_SIZE);
}
