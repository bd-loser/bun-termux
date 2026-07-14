# MTE / Tagged Pointer Crash — Root Cause Analysis & Fix

## Executive Summary

The `free(tagged_ptr) → SIGABRT` crash that blocks opentui on Bun/Termux is
caused by **Android's heap tagging being active** (both MTE hardware AND
Tagged Pointer ABI software check), and **`MEMTAG_OPTIONS=off` doesn't
disable it** on this device.

The fix is to call `android_mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, NONE)`
and `prctl(PR_SET_TAGGED_ADDR_CTRL, 0)` in an LD_PRELOAD constructor that
runs before scudo initializes.

---

## Detailed Analysis

### What the diagnostic revealed

From `scripts/diagnose-mte-crash.ts` output:

```
── H3-A: free(untagged_pointer) ──
   malloc(64)  = 0xb400007ecdbe5000
   untagged    = 0x7ecdbe5000
   💥 SIGABRT
   stderr: Pointer tag for 0x7ecdbe5000 was truncated,
   see 'https://source.android.com/devices/tech/debug/tagged-pointers'.

── H3-B: free(tagged_pointer) ──
   malloc(64)  = 0xb400006fba7d0000
   💥 SIGTRAP
   stderr: Segmentation fault at address 0x6FBA7CFFF0
```

**TWO separate checks are active simultaneously:**

1. **Tagged Pointer ABI (software check)**:
   - `free(untagged_ptr)` → SIGABRT
   - Error: *"Pointer tag for 0x... was truncated"*
   - This is Bionic's software check that verifies free() receives a tagged pointer

2. **MTE (hardware check)**:
   - `free(tagged_ptr)` → SEGFAULT at `untag(ptr) - 16`
   - Scudo's `free()` internally strips the tag before accessing the chunk header
   - MTE hardware rejects the untagged memory access
   - Fault address = `untag(0xb400006fba7d0000) - 16` = `0x6fba7cfff0`

### Why the LD_PRELOAD interception approach doesn't work

The first shim version tried to intercept `malloc`/`free`/`dlsym` to strip
and re-apply tags. This **cannot work** because:

- The H3-B crash happens **inside scudo's own `free()` code** — scudo
  strips the tag internally before accessing the chunk header, then MTE
  hardware rejects the untagged access
- No amount of tag manipulation in the shim can fix a crash that happens
  inside scudo's own code after `free()` receives the correct tagged pointer

### Why MEMTAG_OPTIONS=off doesn't work

`MEMTAG_OPTIONS=off` is checked by Bionic's `__libc_init_malloc_tagging()`
at process startup. On this device, it doesn't disable tagging because:

1. MTE may be force-enabled via the binary's ELF notes
   (`PT_GNU_PROPERTY` with `GNU_PROPERTY_AARCH64_FEATURE_1_MTE`)
2. The kernel may force MTE via init.rc or per-process prctl
3. Bionic on this Android version may not check the env var

---

## The Fix: Disable heap tagging at the source

The new shim (`libbun-mte-fix.c`) is much simpler. It does NOT intercept
malloc/free/dlsym. Instead, it calls two functions in a high-priority
constructor that runs before scudo initializes:

### Step 1: `android_mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, NONE)`

This tells Bionic's allocator (scudo) to:
- Stop tagging pointers in `malloc()` (return untagged pointers)
- Stop checking tags in `free()` (accept untagged pointers)
- Disable the Tagged Pointer ABI software check

### Step 2: `prctl(PR_SET_TAGGED_ADDR_CTRL, 0)`

This disables hardware MTE tag checking for the current thread:
- `PR_TAGGED_ADDR_ENABLE = 0` → disable tagged addressing
- `PR_MTE_TCF_NONE` → no MTE tag check (not even async)

After both calls, the process behaves as if MTE was never enabled:
- `malloc()` returns untagged pointers (top byte = 0x00)
- `free()` accepts untagged pointers without complaint
- No MTE hardware tag checks on memory accesses

### Build & install

```bash
cd ~/bun-termux
git pull origin main
bash src/mte-fix/build-mte-fix.sh full
cp src/mte-fix/libbun-mte-fix.so /data/data/com.termux/files/usr/lib/bun-termux/
```

### Test

```bash
# Run with debug output to verify the shim is loaded and working
BUN_MTE_FIX_DEBUG=1 bun run scripts/diagnose-mte-crash.ts 2>&1 | head -30

# You should see:
# [mte-fix] android_mallopt(SET_HEAP_TAGGING_LEVEL, NONE) OK
# [mte-fix] prctl(PR_SET_TAGGED_ADDR_CTRL, 0) OK — MTE disabled
# [mte-fix] heap tagging disabled successfully
#
# Then H3-A and H3-B should PASS (no crash)
```

### Verify with full debug suite

```bash
bun run scripts/debug-ffi-suite.ts
```

Expected results after fix:
```
✅ Phase 4: free(tagged_pointer)         ← was 💥 SIGABRT
✅ Phase 13: yoga setWidth/setHeight      ← was 💥 CRASH
✅ Phase 14: yogaNodeCalculateLayout      ← was 💥 CRASH
✅ Phase 15: yogaNodeFree                 ← was 💥 CRASH
```

---

## Why this approach works (and previous ones didn't)

| Approach | Why it failed |
|----------|---------------|
| `MEMTAG_OPTIONS=off` in launcher | Doesn't work on this device — MTE force-enabled |
| Intercept malloc/free via LD_PRELOAD | Crash is inside scudo's own code, can't be intercepted |
| Intercept dlsym to redirect malloc/free | Same — crash is inside scudo's free(), not in the call path |
| Side-table: store tag in malloc, re-apply in free | Scudo strips tag internally before chunk header access |
| **`android_mallopt` + `prctl` in constructor** | **✅ Disables tagging at the source, before scudo initializes** |

---

## Files

| File | Purpose |
|------|---------|
| `src/libbun-mte-fix.c` | LD_PRELOAD shim that disables heap tagging via `android_mallopt` + `prctl` |
| `src/build-mte-fix.sh` | Build script |
| `src/README.md` | This file |
| `opentui/scripts/diagnose-mte-crash.ts` | Diagnostic script |

---

## If the fix doesn't work

If `android_mallopt` returns failure, it means scudo was already
initialized before our constructor ran (the dynamic linker called
malloc during library loading). In that case, the only remaining
options are:

1. **Rebuild Bun without MTE ELF notes** — remove
   `-Wl,-z,mmtag-pointer` or similar flag from Bun's build system
   (look in `scripts/build/flags.ts`)

2. **Patch the Bun binary** — use `patchelf` to remove the
   `GNU_PROPERTY_AARCH64_FEATURE_1_MTE` note from the ELF

3. **Use a wrapper process** — start Bun under a parent that calls
   `prctl(PR_SET_TAGGED_ADDR_CTRL, 0)` before `execve()`

Run with `BUN_MTE_FIX_DEBUG=1` to see which calls succeed and which fail.
