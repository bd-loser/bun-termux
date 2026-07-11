#!/usr/bin/env bun
/**
 * bun:ffi test suite — tests all FFI features on our patched Bionic Bun.
 *
 * Run with:  bun run ffi-test.ts
 *
 * Tests:
 *   1. dlopen() — load .so files and call functions
 *   2. CString functions — read C strings from pointers
 *   3. JSCallback — create C callbacks at runtime (TinyCC powered!)
 *   4. cc() — compile C source files (TinyCC powered!)
 *
 * NOTE: Bun 1.3.14 uses JSCallback (not callback) and cc (not linkSymbols with source).
 * The old callback() and linkSymbols(source:...) APIs were replaced.
 */

const ffi = require("bun:ffi");
const { dlopen, JSCallback, cc, CString, ptr, read, suffix } = ffi;
const fs = require("fs");
const os = require("os");

let passed = 0;
let failed = 0;
let skipped = 0;

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

// Detect if we're on Android/Termux
const isAndroid = fs.existsSync("/system/lib64/libc.so");
const libcPath = isAndroid ? "/system/lib64/libc.so" : "/lib/x86_64-linux-gnu/libc.so.6";
const libmPath = isAndroid ? "/system/lib64/libm.so" : "/lib/x86_64-linux-gnu/libm.so.6";

console.log("╔══════════════════════════════════════════════╗");
console.log("║        bun:ffi Test Suite (Bionic)          ║");
console.log("╚══════════════════════════════════════════════╝");
console.log(`  Platform: ${isAndroid ? "Android/Termux" : "Linux"}`);
console.log(`  libc: ${libcPath}`);
console.log(`  Exports: ${Object.keys(ffi).join(", ")}`);
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

test("load libc and call getuid", () => {
  const lib = dlopen(libcPath, {
    getuid: { args: [], returns: "u32" },
  });
  const uid = lib.symbols.getuid();
  if (uid === undefined || uid === null) throw new Error("getuid returned null");
  console.log(`     → getuid() = ${uid}`);
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
  console.log(`     → strcmp('abc','abc') = ${eq}, strcmp('abc','abd') = ${lt}`);
});

// ─── 2. CString functions ──────────────────────────────────────────────
console.log("");
console.log("📝 Test 2: CString functions");

test("CString from libc strdup", () => {
  const lib = dlopen(libcPath, {
    strdup: { args: ["cstring"], returns: "ptr" },
    free: { args: ["ptr"], returns: "void" },
  });
  const dup = lib.symbols.strdup(cstr("hello ffi"));
  const str = new CString(dup);
  assertEqual(String(str), "hello ffi", "CString should return duplicated string");
  lib.symbols.free(dup);
  console.log(`     → strdup + CString = "${str}"`);
});

// ─── 3. JSCallback — TinyCC powered ────────────────────────────────────
console.log("");
console.log("🔧 Test 3: JSCallback — create C callbacks (TinyCC)");

test("JSCallback with i32 arg", () => {
  const cb = new JSCallback({ returns: "i32", args: ["i32"] }, (x) => x * 2);
  if (!cb || typeof cb !== "object") throw new Error("JSCallback not created");
  console.log(`     → JSCallback created (ptr type: ${typeof cb.ptr})`);
});

test("JSCallback passed to C qsort", () => {
  const lib = dlopen(libcPath, {
    qsort: { args: ["ptr", "usize", "usize", "ptr"], returns: "void" },
  });

  const arr = new Int32Array([5, 3, 1, 4, 2]);
  const buf = Buffer.from(arr.buffer);

  const compare = new JSCallback(
    { returns: "i32", args: ["ptr", "ptr"] },
    (a, b) => {
      const av = new DataView(a).getInt32(0, true);
      const bv = new DataView(b).getInt32(0, true);
      return av - bv;
    }
  );

  lib.symbols.qsort(buf, arr.length, 4, compare.ptr);
  
  const expected = [1, 2, 3, 4, 5];
  for (let i = 0; i < 5; i++) {
    if (arr[i] !== expected[i]) {
      throw new Error(`qsort failed: arr[${i}] = ${arr[i]}, expected ${expected[i]}`);
    }
  }
  console.log(`     → qsort([5,3,1,4,2]) = [${arr.join(",")}]`);
});

// ─── 4. cc() — compile C source files (TinyCC) ─────────────────────────
console.log("");
console.log("🔗 Test 4: cc() — compile C source files (TinyCC)");

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

test("cc with factorial", () => {
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

// ─── Summary ───────────────────────────────────────────────────────────
console.log("");
console.log("╔══════════════════════════════════════════════╗");
console.log("║                  Summary                     ║");
console.log("╠══════════════════════════════════════════════╣");
console.log(`║  ✅ Passed:   ${String(passed).padStart(3)}                              ║`);
console.log(`║  ❌ Failed:   ${String(failed).padStart(3)}                              ║`);
console.log(`║  ⏭️  Skipped:  ${String(skipped).padStart(3)}                              ║`);
console.log("╚══════════════════════════════════════════════╝");
console.log("");

if (failed > 0) {
  console.log("❌ Some tests failed!");
  process.exit(1);
} else {
  console.log("🎉 All tests passed! Full bun:ffi support including JSCallback + cc()!");
  process.exit(0);
}
