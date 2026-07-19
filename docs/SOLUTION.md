# FFI Fix Solution — Root Cause Analysis

## Problem

Bun's FFI crashed with `SIGABRT` when calling native functions that take pointer arguments (like `free()`, `yogaNodeFree()`, `yogaNodeCalculateLayout()`) on Android aarch64/Termux.

The crash manifested as:
```
Pointer tag for 0xbf800000bf800000 was truncated
```

## Root Causes

Two separate bugs caused the FFI crashes:

### Bug 1: TinyCC BL Truncation (Pointer Corruption)

**Symptom:** Tagged pointers like `0xb400007df4a26800` were corrupted to `0xbf800000bf800000` (two `-1.0f` floats) when passed through the FFI trampoline.

**Root Cause:** When Bun's FFI trampoline calls a `dlopen`'d function (like libc's `free`), TinyCC creates a PLT entry and emits a `BL` instruction. On Android, libc.so is loaded far away (>128MB) from TinyCC's memfd mapping. The `R_AARCH64_CALL26` relocation **failed the ±128MB range check**.

The original TinyCC code in `arm64-link.c`:
```c
case R_AARCH64_CALL26:
    if (((val - addr) + ((uint64_t)1 << 27)) & ~(uint64_t)0xffffffc)
        tcc_error_noabort("R_AARCH64_(JUMP|CALL)26 relocation failed");
    // ^^^ SILENT error — Bun's error handler suppresses it!
    write32le(ptr, (0x14000000 |
                    (uint32_t)(type == R_AARCH64_CALL26) << 31 |
                    ((val - addr) >> 2 & 0x3ffffff)));
    // ^^^ WRITES TRUNCATED offset anyway — BL jumps to garbage code
```

The BL jumped to garbage code, which clobbered register `x0` with stale SIMD spill data (`0xbf800000bf800000`).

**Why `cc()` worked but `dlopen()` crashed:**
- `cc()` user functions are in TinyCC's memfd mapping (nearby, within ±128MB)
- `dlopen()` functions are in libc.so (far away, out of range)

**Fix:** Patched `arm64-link.c` to generate ARM64 **veneer stubs** when BL offset exceeds ±128MB:

```c
// Veneer stub (12 bytes, in .android_veneer section):
LDR x16, [pc, #8]     // load 64-bit address from literal pool
BR  x16               // jump to the loaded address
.quad target_address  // 8-byte literal
```

The BL is repatched to jump to the veneer (within range), and the veneer jumps to the actual target.

**File:** `patches/tinycc/arm64-link.c.overlay`

---

### Bug 2: Scudo Heap Tagging (free() SIGABRT)

**Symptom:** `free(tagged_ptr)` crashed with `SIGABRT: Pointer tag for 0x... was truncated`.

**Root Cause:** Android's scudo allocator tags heap pointers with a non-zero top byte (e.g., `0xb4`). When `free()` receives a tagged pointer, it checks the tag and aborts if it doesn't match.

Previous attempts failed:
- `MEMTAG_OPTIONS=off` in launcher — doesn't work on all devices (kernel/ELF notes force MTE on regardless)
- `android_mallopt()` — wrong function (doesn't handle this opcode)
- `prctl(PR_SET_TAGGED_ADDR_CTRL)` — doesn't disable scudo's tag generation
- LD_PRELOAD `libbun-mte-fix.so` malloc/free wrapper — runs too late; scudo is already initialized by the time constructors fire

**The correct function:** `mallopt()` (the standard C function), NOT `android_mallopt()`.

`M_BIONIC_SET_HEAP_TAGGING_LEVEL` is handled by `mallopt()` in `libc/bionic/malloc_common.cpp`:
```cpp
extern "C" int mallopt(int param, int value) {
  if (param == M_BIONIC_SET_HEAP_TAGGING_LEVEL) {
    return SetHeapTaggingLevel(static_cast<HeapTaggingLevel>(value));
  }
```

`android_mallopt()` (in `libc/bionic/android_mallopt.cpp`) does NOT handle this opcode — it only handles GWP-ASan, leak info, and profiling options.

**Fix:** Call `mallopt(-204, 0)` at the very first line of `main()`:

```zig
// In src/main.zig
if (Environment.isAndroid) {
    _ = mallopt(-204, 0);  // M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE
}
```

Constants:
- `M_BIONIC_SET_HEAP_TAGGING_LEVEL = -204` (from Bionic's `malloc.h`)
- `M_HEAP_TAGGING_LEVEL_NONE = 0`

**File:** `scripts/apply-android-patches.sh` (PATCH 11)

---

## Verification

The fix was verified with a 18-phase FFI debug suite:

| Phase | Test | Before Fix | After Fix |
|-------|------|-----------|-----------|
| 4 | `free(tagged_ptr)` | 💥 SIGABRT | ✅ PASS |
| 13 | `yogaNodeStyleSetValue(ptr, f32)` | 💥 CRASH | ✅ PASS |
| 14 | `yogaNodeCalculateLayout(ptr, f32, f32)` | 💥 CRASH | ✅ PASS |
| 15 | `yogaNodeFree(ptr)` | 💥 SIGABRT | ✅ PASS |

**Result:** 16/18 phases pass, 0 crashes. The 2 failures are unrelated (stdin raw mode, module resolution).

## Files Modified

| File | Patch | Purpose |
|------|-------|---------|
| `patches/tinycc/arm64-link.c.overlay` | Veneer stubs | Fix BL truncation for out-of-range calls |
| `patches/tinycc/tccrun.c.overlay` | memfd_create | Use memfd instead of /tmp (Android has no /tmp) |
| `scripts/apply-android-patches.sh` | PATCH 11 | Call `mallopt()` in `main()` to disable heap tagging |
| `scripts/apply-android-patches.sh` | PATCH 5 | Enable TinyCC for Android + CONFIG_SELINUX |
| `src/libbun-android-fix.c` | LD_PRELOAD shim | Handle SELinux syscall restrictions |

## References

- [Android Bionic malloc_common.cpp](https://android.googlesource.com/platform/bionic/+/main/libc/bionic/malloc_common.cpp) — `mallopt()` implementation
- [Android Bionic android_mallopt.cpp](https://android.googlesource.com/platform/bionic/+/main/libc/bionic/android_mallopt.cpp) — `android_mallopt()` (does NOT handle heap tagging)
- [ARM64 Architecture Reference Manual](https://developer.arm.com/documentation/ddi0487/latest) — BL instruction range and veneer stubs
- [TinyCC](https://bellard.org/tcc/) — Tiny C Compiler used by Bun's FFI
