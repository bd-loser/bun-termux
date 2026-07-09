<div align="center">

# 🥟 Bun for Termux

### Run Bun natively on Android — no glibc, no wrapper, no proot

[![Build](https://github.com/bd-loser/bun-termux/actions/workflows/build-from-source.yml/badge.svg)](https://github.com/bd-loser/bun-termux/actions/workflows/build-from-source.yml)
[![Release](https://img.shields.io/github/v/release/bd-loser/bun-termux?include_prereleases&label=release)](https://github.com/bd-loser/bun-termux/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bun](https://img.shields.io/badge/Bun-1.3.14-f472b6.svg)](https://bun.sh)
[![Arch](https://img.shields.io/badge/arch-aarch64%20%7C%20x86__64-success.svg)](#-installation)

**`bunx` · `bun install` · `bun run` · `bun build --compile` · monorepo support · all working**

</div>

---

## 🎯 Why this exists

Bun v1.3.14 shipped official Android (Bionic) builds, but they crash on Termux with `CouldntReadCurrentDirectory` because Android SELinux blocks `opendir()` on `/` and `/data` (mode 0771). This repo fixes that — and every other Android-specific issue — with a clean hybrid approach: **source patches for the resolver walk + LD_PRELOAD shim for libc calls**.

**No glibc-runner. No wrapper binary. No userland exec. No proot.** Just Bun, patched to work natively on Android.

<details>
<summary><b>📖 The technical story (click to expand)</b></summary>

Bun's directory resolver walks UP from cwd to `/` calling `opendir()` on every ancestor. On Android, `/` and `/data` are mode `0771` — `opendir()` returns `EACCES`, aborting the walk. This affects `bunx` most because it calls `configureEnvForRun` which triggers the walk.

The tricky part: Bun's resolver uses **raw syscalls** (Zig inline asm, not libc), so an LD_PRELOAD shim can't intercept them. The fix requires **source patches** to prevent the walk from reaching `/` (or handle EACCES in Zig). For libc-level calls (`linkat`, `fopen`, `mkdir`, `execve`), an LD_PRELOAD shim handles everything else.

`bun build --compile` had an additional bug: it stored an absolute ELF vaddr in `BUN_COMPILED.size`, but Android requires PIE binaries with ASLR — the payload is at `base + vaddr`, not `vaddr`. The fix: store an **offset** and use **pointer arithmetic** at runtime.

</details>

---

## ✨ Features

| Feature | Status | How |
|---------|--------|-----|
| `bun --version`, `bun install`, `bun run` | ✅ | Native Bionic binary |
| `bunx <package>` | ✅ | Dedicated launcher with `exec -a "bunx"` |
| `bun build --compile` | ✅ | Source patches: last RW PT_LOAD + offset/pointer-arithmetic |
| Monorepo support (run from subdirs) | ✅ | Source patch: `AccessDenied => continue` (ancestor walking preserved) |
| `os.cpus()` | ✅ | Shim: `/proc/stat` fake via `memfd_create` |
| DNS resolution | ✅ | Shim: `fopen` redirect `/etc/resolv.conf` → `$PREFIX/etc/` |
| `#!/usr/bin/env node` scripts | ✅ | Shim: `execve` shebang translation `/usr/bin/` → `$PREFIX/bin/` |
| `bun --bun` (bun-node shim) | ✅ | Shim: `/tmp` → `$TMPDIR` translation |
| `bun install` (hardlinks) | ✅ | Shim: `linkat`/`symlinkat` copy-on-EACCES fallback |
| Network auto-fix (APAC carriers) | ✅ | `bun-fix-network` (tinyproxy on `127.0.0.1:8888`) |

---

## 📦 Installation

### Quick install (recommended)

```bash
# Download and install the latest .deb in one command (uses $TMPDIR — Termux compatible)
curl -fsSL https://github.com/bd-loser/bun-termux/releases/latest/download/bun_1.3.14-patched_aarch64.deb -o "$TMPDIR/bun.deb" && \
  dpkg -i "$TMPDIR/bun.deb" && rm "$TMPDIR/bun.deb"
```

### Manual install

1. Download `bun_1.3.14-patched_aarch64.deb` from [Releases](https://github.com/bd-loser/bun-termux/releases/latest)
2. Install: `dpkg -i bun_1.3.14-patched_aarch64.deb`
3. (Optional) Fix network: `bun-fix-network`

### pacman (Arch-style)

```bash
pacman -U bun-1.3.14-1-aarch64.pkg.tar.xz
```

<details>
<summary><b>⚠️ Important: Remove stale bunx first</b></summary>

If you previously installed Bun via `curl https://bun.sh/install | bash`, remove its `bunx` so it doesn't shadow this one:

```bash
rm -f ~/.bun/bin/bunx ~/.bun/bin/bun   # remove old install
hash -r                                # refresh shell's command cache
which bunx                             # should print /data/data/com.termux/files/usr/bin/bunx
```

If you see `CouldntReadCurrentDirectory` after install, this is almost always the cause.

</details>

---

## 🚀 Quick start

```bash
# Verify install
bun --version                          # → 1.3.14

# Run a TypeScript file
echo 'console.log("Hello from Bun on Android! 🥟")' > hello.ts
bun run hello.ts

# Use bunx (dedicated launcher — no PATH conflicts)
bunx prettier --version                # → 3.9.4
bunx create-vite my-app --template react-ts

# Compile a standalone binary
bun build --compile hello.ts --outfile hello
./hello                                # runs without Bun installed!

# Install packages
BUN_OPTIONS="--os=android" bun install # --os=android helps with native modules
```

### Frameworks that work

| Framework | Tested | Notes |
|-----------|-------|-------|
| **Angular** | ✅ | `bunx -p @angular/cli ng new`, `bun run start` works |
| **Next.js** | ✅ | `bunx create-next-app`, dev server works |
| **Vite + React** | ✅ | `bunx create-vite`, dev server works |
| **Svelte** | ✅ | `bunx degit sveltejs/template` works |

---

## 🔧 How it works

### Hybrid architecture: source patches + LD_PRELOAD shim

Bun uses **two different syscall paths**, so we need two complementary fix layers:

#### 1. Source patches (for the resolver walk)

Bun's directory resolver uses `std.fs.openDirAbsoluteZ` → Zig's `std.os.linux.openat` — a **raw syscall** (inline asm, NOT libc). LD_PRELOAD shims can ONLY intercept libc function calls, not raw syscalls.

- **`resolver.zig` Layer 1a**: `AccessDenied => continue` instead of `return null` — skips inaccessible ancestors (/, /data) while still processing accessible ones. **Ancestor walking is PRESERVED** (monorepo support works!)
- **`resolver.zig` Layer 1b**: DirEntry cache `.err` branch doesn't return `AccessDenied` — prevents cached EACCES on `/` from propagating on subsequent walks
- **`run_command.zig` Layer 2**: synthesize minimal `DirInfo` when `readDirInfo` returns null — final fallback to prevent `CouldntReadCurrentDirectory`
- **`elf.zig` Layer 4**: `writeBunSection` picks the **last** writable PT_LOAD (fixes RELRO overlap) + stores an **offset** instead of absolute vaddr (fixes PIE/ASLR segfault) — enables `bun build --compile`

#### 2. LD_PRELOAD shim (for libc calls)

`libbun-android-fix.so` intercepts libc-level calls that source patches can't reach:

| Interceptor | What it fixes |
|-------------|---------------|
| `linkat`/`symlinkat`/`renameat` | Copy-on-EACCES fallback (`bun install`) |
| `fopen`/`fopen64` | Redirect `/etc/resolv.conf` → `$PREFIX/etc/` (DNS) |
| `mkdir`/`symlink` | Translate `/tmp` → `$TMPDIR` (`bun --bun`) |
| `execve` | Shebang translation `/usr/bin/` → `$PREFIX/bin/` |
| `getcwd` | Fallback to `/proc/self/cwd` or `$PWD` on EACCES |
| `/proc/stat` fake | `os.cpus()` returns real CPU count (via `memfd_create`) |
| `openat` (3-tier) | Retry without `O_NOFOLLOW` → without `O_DIRECTORY` → `safe_dir_fd` duplicate |

#### 3. `bunx` launcher (packaging)

Uses `exec -a "bunx"` to set `argv[0]="bunx"` so Bun's `isBunX()` detection routes to `BunxCommand.exec()`.

<details>
<summary><b>🏗️ Architecture diagram</b></summary>

```
$PREFIX/bin/bun                → launcher (LD_PRELOAD shim + exec)
$PREFIX/bin/bunx               → launcher (exec -a "bunx" + shim)
$PREFIX/bin/bun-fix-network    → network fix script (tinyproxy)
$PREFIX/lib/bun-termux/bun     → Android-native Bun binary (Bionic-linked)
$PREFIX/lib/bun-termux/libbun-android-fix.so
                               → LD_PRELOAD shim (EACCES fallbacks)
```

Supported architectures: `aarch64`, `x86_64`

</details>

---

## 📋 Troubleshooting

<details>
<summary><b>CouldntReadCurrentDirectory error</b></summary>

You have a stale, unpatched `bunx` earlier in `PATH`. Fix:

```bash
rm -f ~/.bun/bin/bunx
hash -r
which bunx  # should print /data/data/com.termux/files/usr/bin/bunx
```

</details>

<details>
<summary><b>ConnectionRefused during bun install</b></summary>

Your carrier blocks Bun's DNS resolver. Run:

```bash
bun-fix-network
source ~/.bashrc
```

This sets up `tinyproxy` on `127.0.0.1:8888` and routes Bun through it.

</details>

<details>
<summary><b>Native module install fails (node-gyp, better-sqlite3, etc.)</b></summary>

Native C++ modules that need compilation (like `better-sqlite3`) fail because Termux doesn't have Android NDK by default. Workarounds:

```bash
# Use Bun's built-in APIs instead (no compilation needed!)
# Instead of better-sqlite3 → use bun:sqlite:
bun -e "import {Database} from 'bun:sqlite'; const db = new Database(':memory:'); db.run('CREATE TABLE t (x)'); console.log('SQLite works!')"

# Or install build tools and try:
pkg install clang make python binutils
export CC=clang CXX=clang++ npm_config_android_ndk_path=$PREFIX
BUN_OPTIONS="--os=android --verbose" bun add better-sqlite3
```

</details>

<details>
<summary><b>Monorepo: enclosing package.json not found</b></summary>

**Fixed!** The source patches use `AccessDenied => continue` (Layer 1a) which skips inaccessible ancestors while still processing accessible ones. Ancestor walking is **preserved** — Bun finds enclosing `package.json` from parent directories normally.

</details>

<details>
<summary><b>os.cpus() returns empty array</b></summary>

**Fixed!** The shim synthesizes `/proc/stat` via `memfd_create` so `os.cpus()` returns the real CPU count. If you're seeing `[]`, update to the latest build.

</details>

<details>
<summary><b>DNS lookup fails (ENOTFOUND)</b></summary>

The shim redirects `/etc/resolv.conf` → `$PREFIX/etc/resolv.conf`. If DNS still fails:

```bash
ls -la $PREFIX/etc/resolv.conf
# If missing:
pkg install resolv-conf
# Or create manually:
echo "nameserver 8.8.8.8" > $PREFIX/etc/resolv.conf
```

</details>

<details>
<summary><b>#!shebang scripts fail with "No such file or directory"</b></summary>

The shim translates `#!/usr/bin/env node` and similar shebangs to `$PREFIX/bin/env node`. If a script still fails:

```bash
head -1 problematic_script.js
termux-fix-shebang problematic_script.js
```

</details>

---

## 🔨 Building (CI)

Builds are handled by GitHub Actions — no local build required. The **`Build Bun from Source`** workflow cross-compiles with NDK r27c and publishes releases automatically.

To trigger a build manually:
1. Go to [Actions](https://github.com/bd-loser/bun-termux/actions/workflows/build-from-source.yml)
2. Click **"Run workflow"**
3. Wait ~30-60 minutes
4. Download the `.deb` from [Releases](https://github.com/bd-loser/bun-termux/releases/latest)

<details>
<summary><b>🔍 What the CI build does</b></summary>

1. Clones `oven-sh/bun` at tag `bun-v1.3.14`
2. Applies source patches via `scripts/apply-android-patches.sh`:
   - `resolver.zig`: AccessDenied handling (resolver walk)
   - `run_command.zig`: DirInfo fallback (CouldntReadCurrentDirectory)
   - `elf.zig`: last RW PT_LOAD + offset (bun build --compile)
   - `flags.ts` + `tools.ts`: NDK clang 18 cross-compile support
3. Builds with NDK r27c for `aarch64-linux-android28`
4. Compiles `libbun-android-fix.so` (LD_PRELOAD shim)
5. Packages as .deb with `bun` + `bunx` launchers
6. Verifies launchers are correctly installed
7. Publishes release

</details>

---

## 🙏 Credits

This project builds on the work of several people:

- **[Hope2333/bun-termux](https://github.com/Hope2333/bun-termux)** — upstream fork source, original packaging structure and network fix concept
- **[Happ1ness-dev/bun-termux](https://github.com/Happ1ness-dev/bun-termux)** — several LD_PRELOAD shim patterns adapted into our `libbun-android-fix.c`:
  - `safe_dir_fd` duplicate for `O_DIRECTORY` ancestor opens
  - `/proc/stat` faking via `memfd_create`
  - `fopen` redirect for `/etc/resolv.conf` → `$PREFIX/etc/`
  - `mkdir`/`symlink` translation of `/tmp` → `$TMPDIR`
  - `execve` shebang translation `/usr/bin/` → `$PREFIX/bin/`
  - `__OPEN_NEEDS_MODE` for correct `O_TMPFILE` mode extraction
- **[kaan-escober/bun-termux-loader](https://github.com/kaan-escober/bun-termux-loader)** — original userland-exec technique (Happ1ness's base)
- **[oven-sh/bun](https://github.com/oven-sh/bun)** — the Bun runtime itself, by Jarred Sumner and contributors

**This fork adds:**
- Source patches for the resolver walk (`AccessDenied => continue` + cache fix)
- `elf.zig` patches for `bun build --compile` (last RW PT_LOAD + PIE/ASLR offset fix)
- `bunx` launcher using `exec -a "bunx"` for proper `isBunX()` detection
- `execve` shebang fix (use `pathname` not `argv[0]`, matching Linux kernel behavior)
- Bionic-native approach (no glibc-runner, no userland exec, no wrapper binary)

Developed with AI assistance for deep source-code analysis of the Bun runtime.

---

## 📄 License

MIT — see [LICENSE](LICENSE)

<div align="center">

---

**[⭐ Star this repo](../../stargazers)** if it helped you · **[🐛 Report Bug](../../issues)** · **[💡 Request Feature](../../issues)** · **[📥 Releases](../../releases)**

Made with 🥟 for the Termux community

</div>
