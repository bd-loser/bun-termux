# Bun for Termux (Android)

[![Build](https://github.com/bd-loser/bun-termux/actions/workflows/build-from-source.yml/badge.svg)](https://github.com/bd-loser/bun-termux/actions)
[![Bun Version](https://img.shields.io/badge/Bun-1.3.14-blue.svg)](https://github.com/oven-sh/bun/releases/tag/bun-v1.3.14)
[![Platform](https://img.shields.io/badge/Platform-Android%20aarch64-green.svg)](https://termux.dev)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Bun on Android/Termux with full FFI support** — including TinyCC runtime compilation, `cc()`, `JSCallback`, and `dlopen` for native libraries like [opentui](https://github.com/anomalyco/opentui).

## Features

- ✅ **Full FFI support** — `dlopen`, `cc()`, `JSCallback` all work
- ✅ **TinyCC enabled** — compile C code at runtime on Android
- ✅ **opentui compatible** — render TUI apps with yoga layout
- ✅ **Heap tagging fix** — no more `free(tagged_ptr) SIGABRT` crashes
- ✅ **Long-call veneer stubs** — TinyCC generates proper ARM64 veneers for out-of-range calls
- ✅ **SELinux compatibility** — LD_PRELOAD shim handles Android SELinux restrictions

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash
```

## What's Patched

This repository patches Bun v1.3.14 with the following fixes for Android/Termux:

### 1. Resolver — Directory Walking (bunx fix)
Bun's directory resolver uses raw syscalls that fail with EACCES on Android SELinux. Patches the resolver to continue walking on AccessDenied errors.

### 2. ELF Binary Format — `bun build --compile`
Fixes PIE/ASLR issues with Bionic's linker64. Uses the last writable PT_LOAD segment and writes offset (not vaddr) to BUN_COMPILED.

### 3. TinyCC — Runtime C Compilation
- **Enable TinyCC for Android** (disabled upstream)
- **CONFIG_SELINUX=1** — use `mmap(PROT_EXEC)` via memfd instead of mprotect
- **tccrun.c overlay** — use `memfd_create` instead of `/tmp` (Android has no /tmp)
- **arm64-link.c overlay** — generate veneer stubs for out-of-range BL calls

### 4. FFI Library Paths
Adds Android system library and include paths to TinyCC so `cc()` can find `libc.so`.

### 5. Heap Tagging Disable (opentui fix)
Calls `mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE)` at the start of `main()` to disable scudo's heap pointer tagging. Without this, `free(tagged_ptr)` crashes with SIGABRT.

### 6. LD_PRELOAD Shim (`libbun-android-fix.so`)
Intercepts SELinux-restricted syscalls:
- `openat` with O_DIRECTORY on / and /data
- `linkat`/`symlinkat`/`renameat` (fallback to copy)
- `fopen` for `/etc/resolv.conf` → `$PREFIX/etc/`
- `mkdir`/`symlink` for `/tmp` → `$TMPDIR`
- `execve` shebang translation
- `/proc/stat` synthesis for `os.cpus()`

## Documentation

- [FFI Fix Solution](docs/SOLUTION.md) — Detailed root cause analysis and fix
- [Build from Source](docs/BUILD.md) — How to rebuild from source
- [ARMv7 Migration](docs/armv7-migration.md) — Legacy ARMv7 support

## Build from Source

```bash
# Clone this repo
git clone https://github.com/bd-loser/bun-termux.git
cd bun-termux

# The GitHub Actions workflow builds automatically on push to main
# Or trigger manually from the Actions tab

# Build locally (requires NDK r27c, Zig, Rust, CMake)
make build
```

See [docs/BUILD.md](docs/BUILD.md) for detailed build instructions.

## Testing opentui

```bash
# Create a test project
mkdir ~/opentui-test && cd ~/opentui-test
echo '{"dependencies":{"@xincli/opentui-core":"0.4.7","@xincli/opentui-react":"0.4.7"}}' > package.json
bun install

# Create a test app
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

## Credits

- Based on [Happ1ness-dev/bun-termux](https://github.com/Happ1ness-dev/bun-termux) (MIT)
- Builds on [kaan-escober/bun-termux-loader](https://github.com/kaan-escober/bun-termux-loader)
- TinyCC patches inspired by [opencode-termux](https://github.com/opencode-ai/opencode-termux)

## License

MIT — see [LICENSE](LICENSE)
