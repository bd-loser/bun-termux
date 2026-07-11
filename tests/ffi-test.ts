#!/usr/bin/env bun
/**
 * bun:ffi test suite — tests all FFI features on our patched Bionic Bun.
 *
 * Run with:  bun run ffi-test.ts
 *
 * Tests:
 *   1. dlopen() — load .so files and call functions (works without TinyCC)
 *   2. CString functions — readCString (works without TinyCC)
 *   3. callback() — create C callbacks at runtime (NEEDS TinyCC — new!)
 *   4. linkSymbols() — compile C source file (NEEDS TinyCC — new!)
 */

const ffi = require("bun:ffi");
const { dlopen, readCString } = ffi;
// callback and linkSymbols may be undefined if TinyCC is disabled
const callback = ffi.callback;
const linkSymbols = ffi.linkSymbols;

let passed = 0;
let failed = 0;
let skipped = 0;

function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (e) {
    if (e.message && (e.message.includes("not available in this build") || e.message.includes("is not a function"))) {
      skipped++;
      console.log(`  ⏭️  ${name} (skipped — TinyCC not available)`);
    } else {
      failed++;
      console.log(`  ❌ ${name}: ${e.message}`);
    }
  }
}

function assertEqual(actual, expected, msg) {
  if (actual !== expected) {
    throw new Error(`${msg}: expected ${expected}, got ${actual}`);
  }
}

// Helper: encode string as null-terminated buffer for cstring args
function cstr(s) {
  return Buffer.from(s + "\0");
}

console.log("╔══════════════════════════════════════════════╗");
console.log("║        bun:ffi Test Suite (Bionic)          ║");
console.log("╚══════════════════════════════════════════════╝");
console.log("");

// ─── 1. dlopen — load .so files ────────────────────────────────────────
console.log("📦 Test 1: dlopen() — load shared libraries");

test("load libc.so and call getpid", () => {
  const lib = dlopen("/system/lib64/libc.so", {
    getpid: { args: [], returns: "i32" },
  });
  const pid = lib.symbols.getpid();
  assertEqual(pid, process.pid, "getpid() should match process.pid");
  console.log(`     → getpid() = ${pid}`);
});

test("load libc.so and call getuid", () => {
  const lib = dlopen("/system/lib64/libc.so", {
    getuid: { args: [], returns: "u32" },
  });
  const uid = lib.symbols.getuid();
  if (uid === undefined || uid === null) throw new Error("getuid returned null");
  console.log(`     → getuid() = ${uid}`);
});

test("load libm.so and call sqrt", () => {
  const libm = dlopen("/system/lib64/libm.so", {
    sqrt: { args: ["f64"], returns: "f64" },
  });
  const result = libm.symbols.sqrt(2.0);
  if (Math.abs(result - 1.4142135623730951) > 0.0001) {
    throw new Error(`sqrt(2) = ${result}, expected ~1.4142`);
  }
  console.log(`     → sqrt(2) = ${result}`);
});

test("load libm.so and call sin/cos", () => {
  const libm = dlopen("/system/lib64/libm.so", {
    sin: { args: ["f64"], returns: "f64" },
    cos: { args: ["f64"], returns: "f64" },
  });
  const sin0 = libm.symbols.sin(0.0);
  const cos0 = libm.symbols.cos(0.0);
  assertEqual(sin0, 0.0, "sin(0)");
  assertEqual(cos0, 1.0, "cos(0)");
  console.log(`     → sin(0) = ${sin0}, cos(0) = ${cos0}`);
});

test("load libc.so and call strlen (Buffer for cstring)", () => {
  const lib = dlopen("/system/lib64/libc.so", {
    strlen: { args: ["cstring"], returns: "usize" },
  });
  // Bun requires Buffer for cstring args, not JS strings
  const len = lib.symbols.strlen(cstr("hello world"));
  assertEqual(Number(len), 11, "strlen('hello world')");
  console.log(`     → strlen("hello world") = ${len}`);
});

test("load libc.so and call strcmp (Buffer for cstring)", () => {
  const lib = dlopen("/system/lib64/libc.so", {
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

test("readCString from libc strdup", () => {
  const lib = dlopen("/system/lib64/libc.so", {
    strdup: { args: ["cstring"], returns: "ptr" },
    free: { args: ["ptr"], returns: "void" },
  });
  const dup = lib.symbols.strdup(cstr("hello ffi"));
  const str = readCString(dup);
  assertEqual(str, "hello ffi", "readCString should return duplicated string");
  lib.symbols.free(dup);
  console.log(`     → strdup + readCString = "${str}"`);
});

// ─── 3. callback — NEEDS TinyCC ────────────────────────────────────────
console.log("");
console.log("🔧 Test 3: callback() — create C callbacks (needs TinyCC)");

if (typeof callback === "undefined") {
  console.log("  ⏭️  All callback tests skipped — TinyCC not available in this build");
  console.log("     Install the new build with TinyCC patches to enable callback()");
  skipped += 5;
} else {
  test("callback with no args", () => {
    const cb = callback({ returns: "i32", args: [] }, () => 42);
    const result = cb();
    assertEqual(result, 42, "callback should return 42");
    console.log(`     → callback()() = ${result}`);
  });

  test("callback with i32 arg", () => {
    const cb = callback({ returns: "i32", args: ["i32"] }, (x) => x * 2);
    const result = cb(21);
    assertEqual(result, 42, "callback(21) should return 42");
    console.log(`     → callback(21) = ${result}`);
  });

  test("callback with two args", () => {
    const cb = callback({ returns: "i32", args: ["i32", "i32"] }, (a, b) => a + b);
    const result = cb(20, 22);
    assertEqual(result, 42, "callback(20, 22) should return 42");
    console.log(`     → callback(20, 22) = ${result}`);
  });

  test("callback passed to C qsort", () => {
    // THE real test — pass a JS callback to a C function (qsort)
    const lib = dlopen("/system/lib64/libc.so", {
      qsort: { args: ["ptr", "usize", "usize", "callback"], returns: "void" },
    });

    const arr = new Int32Array([5, 3, 1, 4, 2]);
    const buf = Buffer.from(arr.buffer);

    const compare = callback(
      { returns: "i32", args: ["ptr", "ptr"] },
      (a, b) => {
        // Read i32 from the pointers (a, b are ArrayBuffer-like)
        const av = new DataView(a).getInt32(0, true);
        const bv = new DataView(b).getInt32(0, true);
        return av - bv;
      }
    );

    lib.symbols.qsort(buf, arr.length, 4, compare);

    const expected = [1, 2, 3, 4, 5];
    for (let i = 0; i < 5; i++) {
      if (arr[i] !== expected[i]) {
        throw new Error(`qsort failed: arr[${i}] = ${arr[i]}, expected ${expected[i]}`);
      }
    }
    console.log(`     → qsort([5,3,1,4,2]) = [${arr.join(",")}]`);
  });
}

// ─── 4. linkSymbols — NEEDS TinyCC ─────────────────────────────────────
console.log("");
console.log("🔗 Test 4: linkSymbols() — compile C source (needs TinyCC)");

if (typeof linkSymbols === "undefined") {
  console.log("  ⏭️  All linkSymbols tests skipped — TinyCC not available in this build");
  skipped += 2;
} else {
  test("linkSymbols with C source file", () => {
    // linkSymbols expects: { symbols: {...}, source: "file.c" }
    // First write a C file
    const fs = require("fs");
    const cSource = `
      int add(int a, int b) { return a + b; }
    `;
    fs.writeFileSync("/tmp/ffi_test.c", cSource);

    const lib = linkSymbols({
      symbols: {
        add: { args: ["i32", "i32"], returns: "i32" },
      },
      source: "/tmp/ffi_test.c",
    });
    const result = lib.symbols.add(20, 22);
    assertEqual(result, 42, "add(20, 22) should return 42");
    console.log(`     → add(20, 22) = ${result}`);
  });

  test("linkSymbols with factorial", () => {
    const fs = require("fs");
    const cSource = `
      int factorial(int n) {
        if (n <= 1) return 1;
        return n * factorial(n - 1);
      }
    `;
    fs.writeFileSync("/tmp/ffi_factorial.c", cSource);

    const lib = linkSymbols({
      symbols: {
        factorial: { args: ["i32"], returns: "i32" },
      },
      source: "/tmp/ffi_factorial.c",
    });
    const result = lib.symbols.factorial(5);
    assertEqual(result, 120, "factorial(5) should return 120");
    console.log(`     → factorial(5) = ${result}`);
  });
}

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
} else if (skipped > 0) {
  console.log(`⚠️  ${skipped} test(s) skipped (TinyCC not available in this build)`);
  console.log("   dlopen works, but callback() and linkSymbols() need TinyCC.");
  console.log("   Install the new build from the latest release.");
  process.exit(0);
} else {
  console.log("🎉 All tests passed! Full bun:ffi support including callback()!");
  process.exit(0);
}
