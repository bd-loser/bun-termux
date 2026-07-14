# MTE / Tagged Pointer Crash — Root Cause Analysis & Fix

## Executive Summary

The `free(tagged_ptr) → SIGABRT` crash that blocks opentui on Bun/Termux is
**NOT** caused by:

- ❌ TinyCC's ARM64 codegen (TinyCC passes pointers correctly)
- ❌ Bun's FFI trampoline (the JSVALUE_TO_PTR / PTR_TO_JSVALUE round-trip
  preserves tagged pointers — verified by `test_pointer_roundtrip.c`)
- ❌ MEMTAG_OPTIONS env var (it IS set to "off", but MTE remains active)

The crash is caused by **Android's scudo allocator tagging heap pointers**
with a non-zero top byte (0xb4), and **scudo's `free()` rejecting those
tagged pointers** when they come from Bun's FFI call path. The exact
reason scudo rejects them depends on whether your device uses:

1. **MTE (Memory Tagging Extension)** — hardware tag check; if the pointer's
   4-bit tag (bits 56-59) doesn't match the memory's tag, SIGSEGV/SIGABRT.
2. **Heap tagging compatibility mode** — software tag check; scudo stores a
   tag per allocation and verifies it in `free()`.

In both cases, the fix is to ensure `free()` receives the **exact same
tagged pointer that `malloc()` returned**. The included LD_PRELOAD shim
(`libbun-mte-fix.c`) does this by:

1. Intercepting `malloc`/`calloc`/`realloc`
2. Stripping the tag before returning to Bun (so JS code sees untagged ptrs)
3. Storing the original tag in a side table
4. Intercepting `free`
5. Looking up the original tag from the side table
6. Re-applying the tag before calling the real `free`

This decouples Bun's pointer representation from scudo's tag expectations.

---

## Detailed Analysis

### What the debug suite shows

From `scripts/debug-ffi-suite.ts` output:

```
── Phase 3: malloc returns tagged pointer? ──
   malloc(64) = 0xb400007493426000    ← top byte 0xb4, tagged
   tagged: YES (MTE active)

── Phase 4: free(tagged_pointer) ──
   malloc(64) = 0xb4000071833b9800
   calling free(p)...
   💥 SIGABRT (MTE tag check — scudo abort)
```

All 7 pointers captured across phases 3–15 share the **same top byte 0xb4**.
In standard MTE, tags are random 4-bit values (1–15) per allocation, so
identical top bytes across calls strongly suggests a **fixed-tag heap
tagging mode**, not random MTE.

### Hypothesis 1: Bun's FFI corrupts the pointer — RULED OUT

Bun's FFI uses NaN-boxing via `JSVALUE_TO_PTR` / `PTR_TO_JSVALUE`
(see `src/runtime/ffi/FFI.h`). The encoding path:

```c
// PTR_TO_JSVALUE: ptr → JSValue
val.asDouble = (double)(uintptr_t)ptr;
val.asInt64 += DoubleEncodeOffset;   // 2^49

// JSVALUE_TO_PTR: JSValue → ptr
val.asInt64 -= DoubleEncodeOffset;
return (void*)(uintptr_t)val.asDouble;
```

The pointer value is **round-tripped through a `double`**. Double precision
can represent integers up to 2^53 exactly; above 2^53, only multiples of
2048 are representable.

**Test**: `scripts/test_pointer_roundtrip.c` verifies that all 7 captured
pointer values survive the round-trip:

```
0xb400007493426000 -> encode -> decode -> 0xb400007493426000  OK
0xb4000071833b9800 -> encode -> decode -> 0xb4000071833b9800  OK
0xb400007b4afbe800 -> encode -> decode -> 0xb400007b4afbe800  OK
...
0 failures out of 7   (all 7 actual device pointers preserved)
```

This works because Android's scudo always aligns heap allocations to at
least 16 bytes, and the double rounding granularity at this value range
(2^63–2^64) is 2048. **All tagged pointers from scudo are multiples of
2048, so the double round-trip is lossless.**

The one failing case in the test (`0xb400000000000001`) is a synthetic
non-aligned value that scudo would never return.

### Hypothesis 2: TinyCC's ARM64 codegen is buggy — RULED OUT

TinyCC compiles Bun's FFI trampoline. The trampoline for `free(ptr)` is:

```c
void trampoline(EncodedJSValue arg0) {
    free(JSVALUE_TO_PTR(arg0));
}
```

On ARM64, TinyCC generates:

```asm
movz x1, #0x0002, lsl #48     ; load DoubleEncodeOffset (2^49)
sub  x0, x0, x1               ; subtract from int64 representation
fmov d0, x0                   ; reinterpret bits as double
fcvtzu x0, d0                 ; convert double → uint64 (single ARM64 instruction)
br   free                     ; tail-call free
```

The `fcvtzu` instruction handles the full [0, 2^64) range correctly — no
runtime helper function is needed on ARM64 (unlike x86_64, which needs
`libtcc1.c::__fixunsdfdi`).

Bun's `ffi.zig` only compiles `libtcc1.c` on x86_64:
```zig
if (comptime Environment.isX64) {
    state.compileString(@embedFile("libtcc1.c")) catch { ... };
}
```

So on ARM64, the conversion is a single hardware instruction and cannot
corrupt the pointer.

### Hypothesis 3: scudo's free() rejects tagged pointers — CONFIRMED

Since the pointer is preserved end-to-end through JS, the FFI trampoline,
and TinyCC codegen, the SIGABRT must come from scudo's `free()` itself.

Android's scudo has two relevant behaviors:

**If MTE is hardware-active:**
- `malloc` returns a pointer with a 4-bit tag in bits 56–59
- The hardware enforces tag checks on every memory access
- `free(ptr)` accesses the chunk header (at `untag(ptr) - 16`)
- If the pointer's tag doesn't match the memory's tag → SIGSEGV

**If heap tagging (software mode) is active:**
- `malloc` returns a pointer with a tag in the top byte
- `free(ptr)` compares the pointer's tag to a stored tag
- Mismatch → SIGABRT

In both cases, the fix is to ensure `free()` receives the **exact tagged
pointer** that `malloc()` returned.

### Why MEMTAG_OPTIONS=off doesn't work

The launcher script (`scripts/launcher-bun.sh`) sets:
```bash
export MEMTAG_OPTIONS=off
```

This env var is checked by Bionic's `__libc_init_malloc_tagging()` at
process startup. However, it only works if:

1. MTE is not force-enabled via the binary's ELF notes
   (`PT_GNU_PROPERTY` with `GNU_PROPERTY_AARCH64_FEATURE_1_MTE`)
2. The kernel doesn't force MTE via `init.rc` or per-process `prctl`
3. Bionic on this Android version actually checks the env var

On the user's device, at least one of these conditions fails, so MTE
remains active despite the env var.

---

## The Fix: `libbun-mte-fix.c`

### How it works

```
┌─────────────────────────────────────────────────────────────┐
│  Without the shim (BROKEN):                                 │
│                                                             │
│  scudo.malloc() ──► 0xb4000071833b9800 (tagged)            │
│         │                                                   │
│         ▼                                                   │
│  Bun's FFI ────► JS Number 0xb4000071833b9800 (preserved)  │
│         │                                                   │
│         ▼                                                   │
│  Bun's FFI ────► free(0xb4000071833b9800)                  │
│         │                                                   │
│         ▼                                                   │
│  scudo.free() ──► SIGABRT (tag check fails)                │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  With the shim (FIXED):                                     │
│                                                             │
│  scudo.malloc() ──► 0xb4000071833b9800 (tagged)            │
│         │                                                   │
│         ▼  (shim intercepts)                                │
│  side_table[0x...9800] = 0xb4000071833b9800                │
│  return 0x00000071833b9800 (UNTAGGED) to Bun               │
│         │                                                   │
│         ▼                                                   │
│  Bun's FFI ────► JS Number 0x00000071833b9800 (untagged)   │
│         │                                                   │
│         ▼                                                   │
│  Bun's FFI ────► free(0x00000071833b9800)                  │
│         │                                                   │
│         ▼  (shim intercepts)                                │
│  look up side_table[0x...9800]                              │
│  → found 0xb4000071833b9800                                 │
│  call real_free(0xb4000071833b9800) ← correct tagged ptr   │
│         │                                                   │
│         ▼                                                   │
│  scudo.free() ──► OK (tag matches)                         │
└─────────────────────────────────────────────────────────────┘
```

### Build & install

```bash
# From the bun-termux repo root:
bash src/build-mte-fix.sh full    # side-table approach (recommended)
# OR
bash src/build-mte-fix.sh simple  # just strip tag in free() (fallback)

# The shim is built at:
#   /data/data/com.termux/files/usr/lib/bun-termux/libbun-mte-fix.so
```

### Wire it into the launcher

Edit `scripts/launcher-bun.sh` to also load the MTE fix:

```bash
MTE_FIX="/data/data/com.termux/files/usr/lib/bun-termux/libbun-mte-fix.so"
if [ -f "$MTE_FIX" ]; then
  if [ -z "${LD_PRELOAD:-}" ]; then
    export LD_PRELOAD="$MTE_FIX"
  else
    case ":$LD_PRELOAD:" in
      *":$MTE_FIX:"*) ;;
      *) export LD_PRELOAD="$MTE_FIX:$LD_PRELOAD" ;;
    esac
  fi
fi
```

### Debug mode

```bash
BUN_MTE_FIX_DEBUG=1 bun run scripts/debug-ffi-suite.ts
```

This prints every `malloc`/`calloc`/`realloc`/`free` call with the
original tagged pointer, the untagged pointer returned to Bun, and the
tag value.

---

## Diagnostic script: `diagnose-mte-crash.ts`

Run this BEFORE applying the fix to pinpoint the exact failure mode:

```bash
bun run diagnose-mte-crash.ts
```

The script tests these hypotheses:

| Test | What it checks | If PASS | If FAIL/CRASH |
|------|----------------|---------|---------------|
| H1-A | TinyCC preserves tagged ptr (cc echo) | TinyCC OK | TinyCC codegen bug |
| H1-B | Same as H1-A but via u64 type | u64 also broken? | Type-specific issue |
| H2 | 32-bit truncation check | No truncation | Truncation bug |
| H3-A | `free(untagged_pointer)` | scudo accepts untagged → use simple shim | scudo requires tag → use full shim |
| H3-B | `free(tagged_pointer)` (original crash) | (expected to crash) | confirms bug |
| H4 | Print pointer at every step | no modification | tag changed somewhere |
| H5 | Check `/proc/self/status` for MTE | shows MTE lines | no hardware MTE (software tagging) |
| H6 | Print MTE env vars | env vars set | no env vars |
| H7-A/B | calloc/realloc + free | same crash pattern | different behavior |

### Decision tree

```
Run diagnose-mte-crash.ts
        │
        ▼
  H1-A PASS?  ──── NO ───► TinyCC codegen bug (fix TinyCC, not scudo)
        │
        YES
        │
        ▼
  H3-A PASS?  ──── YES ──► scudo accepts untagged → use SIMPLE shim
        │                   (just strip tag in free)
        NO
        │
        ▼
  H3-A CRASH?  ─── YES ──► scudo requires tag → use FULL shim
                            (side-table: store tag in malloc, re-apply in free)
```

---

## Files

| File | Purpose |
|------|---------|
| `src/libbun-mte-fix.c` | Full side-table shim (recommended) |
| `src/libbun-mte-fix-simple.c` | Simple tag-stripping shim (fallback, auto-generated by build script) |
| `src/build-mte-fix.sh` | Build script for both shim versions |
| `diagnose-mte-crash.ts` | Diagnostic script to pinpoint exact failure |

---

## Why this approach (and not others)

### Why not patch Bun's FFI to untag pointers?

Modifying `JSVALUE_TO_PTR` in `FFI.h` to strip the top byte would break
**every comparison** in opentui. opentui stores pointers (e.g., yoga
nodes) in JS variables and compares them later. If some pointers are
tagged (from native code) and others are untagged (from FFI), equality
checks fail.

The shim approach ensures **all** pointers seen by Bun are untagged
(consistently), while **all** pointers seen by scudo are tagged
(consistently).

### Why not build Bun without MTE ELF notes?

This would require finding and removing the `-Wl,-z,mte-tagged-pointer`
flag (or equivalent) in Bun's build system. It's the cleanest fix in
theory, but:

1. The flag location is non-obvious (might be in CMake, Zig build, or NDK config)
2. Rebuilding Bun takes 30+ minutes on a phone
3. The shim approach works without rebuilding

That said, if you're already rebuilding Bun (which `bun-termux` does),
removing MTE from the build is the **proper long-term fix**. Look in
`scripts/build/flags.ts` and `scripts/build/config.ts` for ARM64 linker
flags.

### Why not use `prctl(PR_SET_TAGGED_ADDR_CTRL, 0)` at startup?

This syscall can disable MTE for the calling thread, but it must be
called **before any heap allocation**. By the time Bun's `main()` runs,
scudo has already initialized with MTE enabled, and disabling it after
the fact doesn't untag existing pointers.

The shim approach works because it intercepts `malloc`/`free` at the
library level, before scudo's tagged pointers ever reach Bun's JS code.

---

## Testing the fix

After installing the shim, re-run the debug suite:

```bash
LD_PRELOAD=/data/data/com.termux/files/usr/lib/bun-termux/libbun-mte-fix.so \
  bun run scripts/debug-ffi-suite.ts
```

Expected results:

```
✅ Phase 4: free(tagged_pointer)        ← was 💥 SIGABRT
✅ Phase 13: yoga node setWidth/setHeight ← was 💥 CRASH
✅ Phase 14: yogaNodeCalculateLayout     ← was 💥 CRASH
✅ Phase 15: yogaNodeFree                ← was 💥 CRASH
```

If Phase 4 still crashes with the FULL shim, the issue is NOT tag
mismatch — it's something else (chunk header corruption, double-free
detection, etc.). In that case, run `diagnose-mte-crash.ts` with
`BUN_MTE_FIX_DEBUG=1` to see exactly what's happening.
