# bun-termux → Bun 1.4 port: handoff

Migrated from Claude Code session `2a8a7687-661a-4958-a74c-3fbab1922503` on
2026-08-22. Full history is importable/browsable in opencode as session
`ses_fd72c057cffeSDLHAkPlRYjiSX` (slug `bun-14-migration`, 234 messages).

## Ground rules (from the user, non-negotiable)

- **Never build locally.** All builds go through GitHub CI. This was said
  repeatedly; do not run `bun build`, `cargo build`, or the Makefile targets
  on-device.
- **Prefer source-level patches over the shim.** If a fix is achievable by
  patching Bun's own source, do that and drop the `LD_PRELOAD` workaround.
- **Must stay Bionic.** No glibc/musl assumptions, always Android Bionic
  aarch64.
- In this Termux shell, `grep`/`rg`/`find` are shadowed — prefix with
  `command`.

## The core fact: 1.4.0 is a Zig → Rust rewrite

Verified against the `bun-v1.4.0` tree: **0 `.zig` files, 1523 `.rs` files**.
`build.zig`, `build.zig.zon`, and `CMakeLists.txt` are gone; `Cargo.toml`,
`Cargo.lock`, and `rust-toolchain.toml` are new.

This means every Zig-targeting patch in `scripts/apply-android-patches.sh` is
**dead, not stale** — the anchors can never match. Treat 1.4 as a fresh port.

Path moves:

| 1.3.x | 1.4.0 |
| --- | --- |
| `src/resolver/resolver.zig` | `src/resolver/resolver.rs` |
| `src/cli/run_command.zig` | `src/runtime/cli/run_command.rs` |
| `src/exe_format/elf.zig` | `src/exe_format/elf.rs` |
| `src/standalone_graph/StandaloneModuleGraph.zig` | `.rs` |
| `src/runtime/ffi/ffi.zig` | `src/runtime/ffi/ffi_body.rs` |
| `src/main.zig` | `src/bun_bin/lib.rs` |
| `src/jsc/bindings/EncodingTables.h` | deleted entirely |

`scripts/build/*.ts` and `src/jsc/bindings/c-bindings.cpp` survived, so the
build-script patches still have live anchors.

## Patch verdicts (measured on-device, stock 1.4.0, no patches, no shim)

Tested on aarch64 Termux / Android 12 against the official
`bun-linux-aarch64-android` 1.4.0 build.

### Already work unpatched — delete these patches

Startup, `os.cpus()` (8), DNS/`fetch`, resolver walk / `bun run`,
`bun install`, `bun build --compile` + running the PIE output, `bun:ffi`
`dlopen`, `JSCallback`, `/tmp` writes, `--bun`, child spawn, and `free()` on
scudo-tagged FFI pointers (top byte `b4` survives — so PATCH 11 heap tagging
is unnecessary).

### Superseded upstream (fixed better than we did)

- **PATCH 1** resolver EACCES — `resolver.rs` now treats permission-denied
  *ancestors* as opaque/empty (`EPERM`/`EACCES` → `FD::INVALID`), which is
  exactly what our Layer 1a/1b did.
- **PATCH 3** `bun build --compile` — `elf.rs` now selects the writable
  `PT_LOAD` **containing `.bun` by vaddr** (upstream issue #31023) instead of
  "first writable". Better than our "pick LAST RW PT_LOAD".
- **PATCH 3b** PIE/ASLR — `StandaloneModuleGraph.rs` `get_data()` now adds a
  `load_bias` from `find_loaded_module()`.
- **PATCH 12** `close_range` — now returns `-ENOSYS` gracefully on this
  device rather than trapping.

### Still broken on 1.4.0 — these are the real work

1. **`bun:ffi` `cc()`** — reports "TinyCC is disabled". The `config.ts` gate
   changed shape to `!(abi === "android" || freebsd)`, so the old `sed` no
   longer matches. PATCH 4/5 need new anchors.
2. **`fchmodat2` (452)** — SIGSYS via `SECCOMP_RET_TRAP` when chmod'ing
   extracted bin scripts. Kills `bun install` for any package with a bin
   (rc=159, 3/3 reproducible).
3. **`openat2` (437)** with `RESOLVE_BENEATH` — same SIGSYS, hit immediately
   after fchmodat2.
4. **`bunx`** — `execve` of `.bin/<tool>` returns ENOENT because the shebang
   is `#!/usr/bin/env node` and `/usr/bin/env` doesn't exist on Android.
   Still needs the shim's execve shebang translation (or a source fix).

**Key enabler for #2/#3:** the 1.4.0 binary imports `syscall@LIBC`,
`fchmodat@LIBC`, `chmod@LIBC` — so an `LD_PRELOAD` interposer on `syscall()`
*can* neutralize both trapped syscalls, which was impossible against Zig-era
raw-syscall inline asm. Verified: a ~40-line `syscall()` interposer emulating
452 via `fchmodat(...,0)` and 437 via `openat()` makes `bun install` of
cowsay, rimraf, and typescript all succeed. Per the user's preference, try
for a source-level fix first and keep this as the fallback.

## TinyCC

Pin moved `12882eee` → `05f0fafa`. Our `patches/tinycc/arm64-link.c.overlay`
(14489 B) was a stale **full-file copy** vs upstream's 15592 B, so reusing it
would silently revert upstream changes. The veneer fix (17 refs) is still
absent upstream, so it must be **regenerated against the new pin, not
reused**.

Already done in the working tree: both overlays were converted to real
unified diffs — `patches/tinycc/arm64-link.c.patch` and
`patches/tinycc/tccrun.c.patch` (the latter carries the Android
`memfd_create` fix for the `CONFIG_SELINUX` path, preserving the `MAP_FIXED`
two-mapping layout that `tcc_relocate()`'s `ptr_diff` arithmetic depends on).
`CONFIG_SELINUX=1` is the key define: Android SELinux blocks
`mprotect(PROT_EXEC)` on heap pages, and that path maps `PROT_EXEC` from a
shared fd instead.

## Open tasks

1. ~~**Rewrite `scripts/apply-android-patches.sh` for 1.4**~~ **DONE.** New
   script carries 7 patches, all verified against the real 1.4.0 tree
   (applied cleanly to reference downloads in a sandbox tree; idempotent on
   re-run; rustc parse-clean on all 4 touched `.rs` files; Bun.Transpiler
   parse-clean on all 3 touched `.ts` files):
   - P1 `scripts/build/config.ts` — TinyCC gate → `?? !freebsd`
   - P2 `scripts/build/deps/tinycc.ts` — wire `patches/tinycc/*.patch` +
     `CONFIG_SELINUX=1`
   - P3 `scripts/build/tools.ts` — LLVM 21.1.8→18.0.2 (NDK r27c)
   - P4 `src/sys/lib.rs` — lchmod: compile-time `fchmodat` fallback
     (fchmodat2 is seccomp-TRAPPED, not ENOSYS)
   - P5 `src/sys/linux_syscall.rs` — openat2_beneath/_in_root → openat
   - P6 `src/spawn_sys/posix_spawn.rs` — shebang remap in `spawn_z`
     (`android_shebang_remap`: missing `/usr/bin|/bin|…` interpreter →
     `$PREFIX/bin`, argv rebuilt `[interp, script, …]`)
   - P7 `src/runtime/ffi/ffi_body.rs` — TCC search paths:
     `/system/lib64` + `$PREFIX/{include,include/aarch64-linux-android,lib}`
   Note: old PATCH 12 (c-bindings.cpp close_range) turned out already-fixed
   upstream — Linux branch is a raw `syscall(__NR_close_range)` in 1.4.
2. ~~**Update `.github/workflows/build-from-source.yml` for Rust**~~ **DONE.**
   Uses upstream's `android-release` profile (`bun scripts/build.ts
   --profile=android-release`): os=linux arch=aarch64 abi=android,
   webkit=prebuilt. The build system itself wires
   `CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER`, `--target/--sysroot`, and
   links NDK compiler-rt/libunwind into the host clang resource dir.
   NDK r27c provides the bionic sysroot only — host clang stays Ubuntu's
   clang-18 (matches PATCH 3). Rust toolchain comes from rust-toolchain.toml
   via rustup auto-install. Zig steps deleted. Shim download/build steps
   deleted from package-deb; deb verify asserts the shim is ABSENT.
3. ~~**Drop the `LD_PRELOAD` shim**~~ **DONE.** Deleted
   `src/libbun-android-fix.c` and `scripts/build-shim.sh`. Launchers
   rewritten without LD_PRELOAD (bunx keeps the critical `exec -a "bunx"`).
4. ~~**Bump version strings 1.3.14 → 1.4.0**~~ **DONE.** Makefile `PKGVER`,
   `scripts/install.sh` deb name + release URL, README badge/body/table.

## Remaining before first 1.4 release

- Run the workflow once (`workflow_dispatch` with version=1.4.0) and fix
  whatever CI-only failures surface (expected: none in patching; possible
  friction in cargo/NDK env details).
- On-device smoke test of the produced binary: bun install / bunx cowsay /
  cc() + JSCallback / shebang script spawn.
- README still links to `docs/BUILD.md`, which doesn't exist (pre-existing).

## Working-tree state at migration

Uncommitted, nothing pushed:

- `patches/tinycc/{arm64-link,tccrun}.c.overlay` deleted (staged), replaced
  by `.patch` files.
- ~~Scratch reference copies of upstream files at repo root~~ **deleted**
  (2026-08-22): the `.zig` ones were literal `404: Not Found` stubs; the rest
  were byte-identical duplicates of `~/bunwork/v140/*`. Reference tree lives
  only in `~/bunwork/v140/` now.
