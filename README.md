# Bun for Termux — Android aarch64 with FFI, TinyCC, and opentui support

> Run [Bun](https://bun.sh) natively on Android/Termux with full FFI, runtime C compilation via TinyCC, `dlopen` for native libraries, and working [opentui](https://github.com/anomalyco/opentui) TUI rendering. Bionic-native. No proot. No glibc-runner. No userland-exec.

[![Build](https://github.com/bd-loser/bun-termux/actions/workflows/build-from-source.yml/badge.svg)](https://github.com/bd-loser/bun-termux/actions)
[![Bun Version](https://img.shields.io/badge/Bun-1.4.0-blue.svg)](https://github.com/oven-sh/bun/releases/tag/bun-v1.4.0)
[![Platform](https://img.shields.io/badge/Platform-Android%20aarch64-green.svg)](https://termux.dev)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Termux](https://img.shields.io/badge/Termux-Bionic--native-brightgreen.svg)](https://termux.dev)

**Keywords:** bun android · bun termux · bun aarch64 · bun arm64 android · bun ffi termux · tinycc android · opentui termux · javascript runtime android · typescript termux · bun native android · bionic bun

---

## Why this fork

Bun 1.4 ships an official Android (Bionic-linked) build and fixed most of the 1.3-era pain itself — the resolver walk, `bun build --compile` PIE handling, DNS, `os.cpus()`, and `/tmp` all work out of the box. What still breaks on Termux (verified against stock 1.4.0 on-device):

- **`bun install` dies with SIGSYS** — Android's zygote seccomp profile *traps* `fchmodat2(452)` and `openat2(437)` instead of returning `ENOSYS`, so upstream's runtime fallbacks never run.
- **`bunx <pkg>` fails with ENOENT** — npm shims carry `#!/usr/bin/env node` shebangs and Android has no `/usr/bin`.
- **`bun:ffi cc()` reports "TinyCC is disabled"** — upstream gates TinyCC off on Android.

This fork fixes exactly those, at source level.

## Features

- **Source-level only** — every fix compiled into the binary via `#[cfg(target_os = "android")]`; no LD_PRELOAD, no termux-exec
- **Full FFI support** — `dlopen`, `cc()`, `JSCallback` all work
- **TinyCC enabled on Android** — SELinux-safe JIT memory (`memfd_create`) + ARM64 long-call veneers
- **Seccomp-trap bypass** — `lchmod` and resolver walks avoid `fchmodat2`/`openat2`
- **Shebang remap** — missing-interpreter scripts exec from `$PREFIX/bin`
- **`bunx` fix** — launcher sets `argv[0]` correctly; scripts spawn cleanly

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash
```

That's it. Installs `bun` and `bunx` into `$PREFIX/bin` on Termux (aarch64).

## Verify

```bash
bun --version              # 1.4.0
bun -e "console.log(require('os').cpus().length)"  # real CPU count
bunx cowsay hello          # shebang remap + spawn work on Android
bun install                # no fchmodat2/openat2 SIGSYS
bun -e "const {cc}=require('bun:ffi');console.log(typeof cc)"  # function
```

## What's Patched

Seven patches, applied by [`scripts/apply-android-patches.sh`](scripts/apply-android-patches.sh). Every Rust fix is a compile-time `#[cfg(target_os = "android")]` branch — Android's seccomp returns `SECCOMP_RET_TRAP` (SIGSYS) for blocked syscalls, not `ENOSYS`, so runtime fallbacks can never fire.

### Build system
1. **`config.ts`** — enable TinyCC on Android (upstream disables it)
2. **`deps/tinycc.ts`** — wire in our TinyCC source patches + `CONFIG_SELINUX=1`
3. **`tools.ts`** — accept LLVM/clang 18 (NDK r27c / Ubuntu)

### Syscall fixes
4. **`src/sys/lib.rs`** — `lchmod` uses `fchmodat(AT_SYMLINK_NOFOLLOW)` instead of the seccomp-trapped `fchmodat2(452)`
5. **`src/sys/linux_syscall.rs`** — resolver walks use plain `openat` instead of the trapped `openat2(437)`

### Spawn & FFI
6. **`src/spawn_sys/posix_spawn.rs`** — when the exec target is a script whose shebang names a *missing* interpreter, remap `/usr/bin|/bin|…` to `$PREFIX/bin` and rebuild argv `[interp, script, …]` (replaces termux-exec)
7. **`src/runtime/ffi/ffi_body.rs`** — TinyCC finds Bionic libc (`/system/lib64`) and Termux headers/libs (`$PREFIX/include`, `$PREFIX/lib`)

Plus two TinyCC source patches (against Bun's pinned commit): `tccrun.c` maps executable memory via `memfd_create` (SELinux blocks `mprotect(PROT_EXEC)` on heap), and `arm64-link.c` emits veneer stubs for out-of-range BL calls.

## Compatibility

| Item | Status |
|---|---|
| Architecture | `aarch64` (arm64) |
| Android | 10+ (API 29+, SELinux untrusted_app_27+) |
| Termux | Termux app + Termux:API optional |
| Bun version | 1.4.0 |
| Node built-ins | `os`, `fs`, `net`, `dns`, `child_process` — work unpatched in 1.4 |
| `bun install` | Works (fchmodat2/openat2 bypass) |
| `bun run` | Works |
| `bun build --compile` | Works (fixed upstream in 1.4) |
| `bunx <pkg>` | Works (shebang remap) |
| `bun:ffi` `dlopen` | Works |
| `bun:ffi` `cc()` (TinyCC) | Works |
| `bun:ffi` `JSCallback` | Works |
| opentui (`@xincli/opentui-core`) | Works |

## Testing opentui

```bash
mkdir ~/opentui-test && cd ~/opentui-test
echo '{"dependencies":{"@xincli/opentui-core":"0.4.7","@xincli/opentui-react":"0.4.7"}}' > package.json
bun install

cat > app.jsx << 'EOF'
import { createCliRenderer } from "@xincli/opentui-core"
import { createRoot } from "@xincli/opentui-react"

const renderer = await createCliRenderer({ exitOnCtrlC: false })
const root = createRoot(renderer)
root.render(<box border><text>Hello opentui!</text></box>)
await new Promise(r => setTimeout(r, 3000))
renderer.destroy()
EOF

bun run app.jsx
```

## Build from Source

Requires Rust (pinned via `rust-toolchain.toml`), NDK r27c, clang 18, CMake, Ninja, and Bun for bootstrapping.

```bash
git clone https://github.com/oven-sh/bun.git /tmp/bun-src   # bun-v1.4.0
git clone https://github.com/bd-loser/bun-termux.git
cd bun-termux
BUN_SRC=/tmp/bun-src bash scripts/apply-android-patches.sh
cd /tmp/bun-src
ANDROID_NDK_ROOT=/path/to/ndk bun scripts/build.ts --profile=android-release
```

CI builds on manual dispatch and a weekly cron (see `.github/workflows/build-from-source.yml`).

See [docs/BUILD.md](docs/BUILD.md) for detailed build instructions.

## Documentation

- [docs/SOLUTION.md](docs/SOLUTION.md) — Root cause analysis for the FFI/heap-tagging fix
- [docs/BUILD.md](docs/BUILD.md) — Building from source
- [docs/armv7-migration.md](docs/armv7-migration.md) — Legacy ARMv7 notes

## Credits

- **Upstream fork ancestry:** [Hope2333/bun-termux](https://github.com/Hope2333/bun-termux) (MIT) — original pure-android packaging scaffolding (Makefile, deb/pacman targets, docs skeleton). This fork extends it with source-level patches, launcher scripts, and full-FFI support.
- **Historical shim:** the 1.3.x releases used an LD_PRELOAD shim (`libbun-android-fix.c`) adapting patterns from [Happ1ness-dev/bun-termux](https://github.com/Happ1ness-dev/bun-termux) (MIT). The shim was removed in the 1.4 port — all fixes are in-source now.
- **TinyCC** — LGPL-2.1 upstream ([tinycc](https://repo.or.cz/tinycc.git)); overlay modifications for Android SELinux + ARM64 veneers are contributed under LGPL.
- **Bun** — MIT © Oven, Inc. ([oven-sh/bun](https://github.com/oven-sh/bun))

Full attribution and scope: [LICENSE](LICENSE).

## License

MIT — see [LICENSE](LICENSE) for full text and third-party attribution (Hope2333, Happ1ness-dev, TinyCC/LGPL, Bun/MIT).

---

<sub>Suggested GitHub repo topics: `bun` `termux` `android` `aarch64` `arm64` `javascript-runtime` `typescript` `ffi` `tinycc` `opentui` `bionic` `selinux` `bunx` `nodejs-alternative` `dlopen`</sub>
