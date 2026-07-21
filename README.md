# Bun for Termux — Android aarch64 with FFI, TinyCC, and opentui support

> Run [Bun](https://bun.sh) natively on Android/Termux with full FFI, runtime C compilation via TinyCC, `dlopen` for native libraries, and working [opentui](https://github.com/anomalyco/opentui) TUI rendering. Bionic-native. No proot. No glibc-runner. No userland-exec.

[![Build](https://github.com/bd-loser/bun-termux/actions/workflows/build-from-source.yml/badge.svg)](https://github.com/bd-loser/bun-termux/actions)
[![Bun Version](https://img.shields.io/badge/Bun-1.3.14-blue.svg)](https://github.com/oven-sh/bun/releases/tag/bun-v1.3.14)
[![Platform](https://img.shields.io/badge/Platform-Android%20aarch64-green.svg)](https://termux.dev)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Termux](https://img.shields.io/badge/Termux-Bionic--native-brightgreen.svg)](https://termux.dev)

**Keywords:** bun android · bun termux · bun aarch64 · bun arm64 android · bun ffi termux · tinycc android · opentui termux · javascript runtime android · typescript termux · bun native android · bionic bun

---

## Why this fork

Bun 1.3.14 is the first official Android (Bionic-linked PIE) build, but several Android/SELinux/Bionic quirks break real-world usage on Termux: the directory resolver hits `EACCES` on `openat(O_DIRECTORY)`, `bun install` fails on `linkat`/`symlinkat`, `os.cpus()` returns `[]` because `/proc/stat` is restricted, DNS breaks without `/etc/resolv.conf`, `bun --bun` fails writing to `/tmp`, `bun build --compile` outputs broken PIE binaries, TinyCC is disabled, and Scudo's heap pointer tagging crashes `free()` on FFI pointers from libraries like opentui.

This fork fixes every one of those.

## Features

- **Full FFI support** — `dlopen`, `cc()`, `JSCallback` all work
- **TinyCC enabled on Android** — compile C code at runtime
- **opentui compatible** — render TUI apps with yoga layout
- **Heap tagging fix** — no more `free(tagged_ptr) SIGABRT` crashes on FFI
- **ARM64 long-call veneers** — TinyCC generates proper stubs for out-of-range BL
- **SELinux-safe LD_PRELOAD shim** — Bionic-native, zero glibc/proot overhead
- **`bun build --compile` fix** — correct PIE offsets for Bionic's linker64
- **`bunx` fix** — resolver tolerates SELinux `EACCES` on ancestor walk
- **DNS / os.cpus() / shebang / /tmp** — all working via targeted intercepts

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash
```

That's it. Installs `bun` and `bunx` into `$PREFIX/bin` on Termux (aarch64).

## Verify

```bash
bun --version              # 1.3.14
bun -e "console.log(require('os').cpus().length)"  # real CPU count, not 0
bunx cowsay hello          # resolver walk works on Android SELinux
```

## What's Patched

Every fix here targets a concrete failure mode of stock Bun 1.3.14 on Android/Termux.

### 1. Resolver — directory walking (`bunx` fix)
Bun's directory resolver uses raw syscalls that fail with `EACCES` on Android SELinux (untrusted_app_27+ blocks `openat(O_DIRECTORY)` on `/` and `/data`). Patched to continue walking on `AccessDenied`.

### 2. ELF binary format — `bun build --compile`
Fixes PIE/ASLR issues with Bionic's linker64. Uses the last writable `PT_LOAD` segment and writes offset (not vaddr) to `BUN_COMPILED`.

### 3. TinyCC — runtime C compilation on Android
- **Enable TinyCC for Android** (disabled upstream)
- **`CONFIG_SELINUX=1`** — use `mmap(PROT_EXEC)` via memfd instead of mprotect
- **`tccrun.c` overlay** — `memfd_create` instead of `/tmp` (Android has no `/tmp`)
- **`arm64-link.c` overlay** — generate veneer stubs for out-of-range BL calls

### 4. FFI library paths
Adds Android system library and include paths (`/system/lib64`, `$PREFIX/include`, NDK sysroot) to TinyCC so `cc()` can find `libc.so`.

### 5. Heap tagging disable (opentui / FFI fix)
Calls `mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE)` at the start of `main()` to disable Scudo's heap pointer tagging. Without this, `free(tagged_ptr)` from an FFI-allocated pointer crashes with `SIGABRT`.

### 6. LD_PRELOAD shim (`libbun-android-fix.so`)
Bionic-native (no glibc, no userland-exec). Intercepts SELinux-restricted syscalls:
- `openat` with `O_DIRECTORY` on `/` and `/data` → dup a safe fd
- `linkat`/`symlinkat`/`renameat` → fall back to `copy` on `EACCES`/`EXDEV`
- `fopen` for `/etc/resolv.conf`/`nsswitch.conf`/`hosts` → `$PREFIX/etc/`
- `mkdir`/`symlink` for `/tmp` → `$TMPDIR`
- `execve` shebang translation (`/usr/bin/env node` → `$PREFIX/bin/env`)
- `/proc/stat` synthesis for `os.cpus()`

## Compatibility

| Item | Status |
|---|---|
| Architecture | `aarch64` (arm64) |
| Android | 10+ (API 29+, SELinux untrusted_app_27+) |
| Termux | Termux app + Termux:API optional |
| Bun version | 1.3.14 |
| Node built-ins | `os`, `fs`, `net`, `dns`, `child_process` — verified working |
| `bun install` | Works (linkat fallback) |
| `bun run` | Works |
| `bun build --compile` | Works (PIE fix) |
| `bunx <pkg>` | Works (resolver fix) |
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

Requires NDK r27c, Zig, Rust, CMake.

```bash
git clone https://github.com/bd-loser/bun-termux.git
cd bun-termux
make build
```

CI builds automatically on push to `main` (see `.github/workflows/`).

See [docs/BUILD.md](docs/BUILD.md) for detailed build instructions.

## Documentation

- [docs/SOLUTION.md](docs/SOLUTION.md) — Root cause analysis for the FFI/heap-tagging fix
- [docs/BUILD.md](docs/BUILD.md) — Building from source
- [docs/armv7-migration.md](docs/armv7-migration.md) — Legacy ARMv7 notes

## Credits

- **Upstream fork ancestry:** [Hope2333/bun-termux](https://github.com/Hope2333/bun-termux) (MIT) — original pure-android packaging scaffolding (Makefile, deb/pacman targets, docs skeleton). This fork extends it with source-level patches, LD_PRELOAD shim, TinyCC overlays, launcher scripts, and full-FFI support.
- **Shim patterns:** [Happ1ness-dev/bun-termux](https://github.com/Happ1ness-dev/bun-termux) (MIT) — `src/libbun-android-fix.c` adapts patterns from their `shim.c`: `safe_dir_fd` EACCES-dup, `/proc/stat` memfd synthesis, `fopen` `/etc` redirect, execve shebang translation, `/tmp` → `$TMPDIR`, `linkat` EXDEV fallback, `__OPEN_NEEDS_MODE`. Their fork uses userland-exec + glibc; this fork ports the patterns to Bionic-native.
- **TinyCC** — LGPL-2.1 upstream ([tinycc](https://repo.or.cz/tinycc.git)); overlay modifications for Android SELinux + ARM64 veneers are contributed under LGPL.
- **Bun** — MIT © Oven, Inc. ([oven-sh/bun](https://github.com/oven-sh/bun))

Full attribution and scope: [LICENSE](LICENSE).

## License

MIT — see [LICENSE](LICENSE) for full text and third-party attribution (Hope2333, Happ1ness-dev, TinyCC/LGPL, Bun/MIT).

---

<sub>Suggested GitHub repo topics: `bun` `termux` `android` `aarch64` `arm64` `javascript-runtime` `typescript` `ffi` `tinycc` `opentui` `bionic` `selinux` `bunx` `nodejs-alternative` `dlopen`</sub>
