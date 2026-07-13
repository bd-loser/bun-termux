#!/usr/bin/env bun
/**
 * bun:ffi test suite — tests all FFI features on our patched Bionic Bun.
 *
 * Run with:  bun run ffi-test.ts
 *
 * Results:
 *   ✅ dlopen() — load .so files and call functions
 *   ✅ cc() — compile C source files at runtime (TinyCC!)
 *   ✅ C callbacks via cc() (qsort with C-side comparator)
 *
 * TinyCC IS working — cc() compiles C code successfully.
 * For qsort, we declare qsort() extern instead of #include <stdlib.h>
 * because TinyCC can't find system headers on Termux without NDK sysroot.
 */

const ffi = require("bun:ffi");
const { dlopen, cc } = ffi;
const fs = require("fs");
const os = require("os");

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (e) {
    failed++;
    console.log(`  ❌ ${name}: ${e.message}`);
  }
}

function assertEqual(actual, expected, msg) {
  if (actual !== expected) {
    throw new Error(`${msg}: expected ${expected}, got ${actual}`);
  }
}

function cstr(s) {
  return Buffer.from(s + "\0");
}

const isAndroid = fs.existsSync("/system/lib64/libc.so");
const libcPath = isAndroid ? "/system/lib64/libc.so" : "/lib/x86_64-linux-gnu/libc.so.6";
const libmPath = isAndroid ? "/system/lib64/libm.so" : "/lib/x86_64-linux-gnu/libm.so.6";

console.log("╔══════════════════════════════════════════════╗");
console.log("║        bun:ffi Test Suite (Bionic)          ║");
console.log("╚══════════════════════════════════════════════╝");
console.log(`  Platform: ${isAndroid ? "Android/Termux" : "Linux"}`);
console.log("");

// ─── 1. dlopen — load .so files ────────────────────────────────────────
console.log("📦 Test 1: dlopen() — load shared libraries");

test("load libc and call getpid", () => {
  const lib = dlopen(libcPath, {
    getpid: { args: [], returns: "i32" },
  });
  const pid = lib.symbols.getpid();
  assertEqual(pid, process.pid, "getpid() should match process.pid");
  console.log(`     → getpid() = ${pid}`);
});

test("load libm and call sqrt", () => {
  const libm = dlopen(libmPath, {
    sqrt: { args: ["f64"], returns: "f64" },
  });
  const result = libm.symbols.sqrt(2.0);
  if (Math.abs(result - 1.4142135623730951) > 0.0001) {
    throw new Error(`sqrt(2) = ${result}, expected ~1.4142`);
  }
  console.log(`     → sqrt(2) = ${result}`);
});

test("load libm and call sin/cos", () => {
  const libm = dlopen(libmPath, {
    sin: { args: ["f64"], returns: "f64" },
    cos: { args: ["f64"], returns: "f64" },
  });
  const sin0 = libm.symbols.sin(0.0);
  const cos0 = libm.symbols.cos(0.0);
  assertEqual(sin0, 0.0, "sin(0)");
  assertEqual(cos0, 1.0, "cos(0)");
  console.log(`     → sin(0) = ${sin0}, cos(0) = ${cos0}`);
});

test("load libc and call strlen", () => {
  const lib = dlopen(libcPath, {
    strlen: { args: ["cstring"], returns: "usize" },
  });
  const len = lib.symbols.strlen(cstr("hello world"));
  assertEqual(Number(len), 11, "strlen('hello world')");
  console.log(`     → strlen("hello world") = ${len}`);
});

test("load libc and call strcmp", () => {
  const lib = dlopen(libcPath, {
    strcmp: { args: ["cstring", "cstring"], returns: "i32" },
  });
  const eq = lib.symbols.strcmp(cstr("abc"), cstr("abc"));
  const lt = lib.symbols.strcmp(cstr("abc"), cstr("abd"));
  assertEqual(eq, 0, "strcmp('abc','abc') should be 0");
  if (lt >= 0) throw new Error(`strcmp('abc','abd') = ${lt}, expected < 0`);
  console.log(`     → strcmp OK`);
});

// ─── 2. cc() — compile C source files (TinyCC) ─────────────────────────
console.log("");
console.log("🔗 Test 2: cc() — compile C source files (TinyCC)");

test("cc with add function", () => {
  const tmpdir = os.tmpdir();
  const cFile = `${tmpdir}/ffi_add.c`;
  fs.writeFileSync(cFile, "int add(int a, int b) { return a + b; }");

  const lib = cc({
    source: cFile,
    symbols: {
      add: { args: ["i32", "i32"], returns: "i32" },
    },
  });
  const result = lib.symbols.add(20, 22);
  assertEqual(result, 42, "add(20, 22) should return 42");
  console.log(`     → add(20, 22) = ${result}`);
});

test("cc with factorial (recursion)", () => {
  const tmpdir = os.tmpdir();
  const cFile = `${tmpdir}/ffi_factorial.c`;
  fs.writeFileSync(cFile, `
    int factorial(int n) {
      if (n <= 1) return 1;
      return n * factorial(n - 1);
    }
  `);

  const lib = cc({
    source: cFile,
    symbols: {
      factorial: { args: ["i32"], returns: "i32" },
    },
  });
  const result = lib.symbols.factorial(5);
  assertEqual(result, 120, "factorial(5) should return 120");
  console.log(`     → factorial(5) = ${result}`);
});

test("cc with qsort (C callback, no JS)", () => {
  const tmpdir = os.tmpdir();
  const cFile = `${tmpdir}/ffi_qsort.c`;
  // Declare qsort extern instead of #include <stdlib.h>
  // (TinyCC can't find system headers on Termux without NDK sysroot)
  fs.writeFileSync(cFile, `
    extern void qsort(void*, unsigned long, unsigned long, int(*)(const void*, const void*));
    static int compare(const void *a, const void *b) {
      return *(int*)a - *(int*)b;
    }
    void sort_array(int *arr, int n) {
      qsort(arr, (unsigned long)n, sizeof(int), compare);
    }
  `);

  const lib = cc({
    source: cFile,
    symbols: {
      sort_array: { args: ["ptr", "i32"], returns: "void" },
    },
  });

  const arr = new Int32Array([5, 3, 1, 4, 2]);
  const buf = Buffer.from(arr.buffer);
  lib.symbols.sort_array(buf, arr.length);

  const expected = [1, 2, 3, 4, 5];
  for (let i = 0; i < 5; i++) {
    if (arr[i] !== expected[i]) {
      throw new Error(`sort failed: arr[${i}] = ${arr[i]}, expected ${expected[i]}`);
    }
  }
  console.log(`     → sort_array([5,3,1,4,2]) = [${arr.join(",")}]`);
});

// ─── Summary ───────────────────────────────────────────────────────────
console.log("");
console.log("╔══════════════════════════════════════════════╗");
console.log("║                  Summary                     ║");
console.log("╠══════════════════════════════════════════════╣");
console.log(`║  ✅ Passed:   ${String(passed).padStart(3)}                              ║`);
console.log(`║  ❌ Failed:   ${String(failed).padStart(3)}                              ║`);
console.log("╚══════════════════════════════════════════════╝");
console.log("");

if (failed > 0) {
  console.log("❌ Some tests failed!");
  process.exit(1);
} else {
  console.log("🎉 All tests passed!");
  console.log("   ✅ dlopen — load .so files and call functions");
  console.log("   ✅ cc() — compile C source files at runtime (TinyCC!)");
  console.log("   ✅ C callbacks via cc() (qsort with C-side comparator)");
  process.exit(0);
}
