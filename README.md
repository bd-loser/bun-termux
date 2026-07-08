<div align="center">

# 🥟 Bun for Termux

**Native Android Bun runtime — no glibc, no wrapper, no grun.**

Bun v1.3.14+ ships official Android builds as Bionic-linked PIE executables that run directly on Termux via `/system/bin/linker64`. This repo packages them with **SELinux EACCES fixes**, **`bunx` support**, and a **network auto-fix** for APAC carriers.

`aarch64` · `x86_64` · MIT License

</div>

---

## ✨ Features

- **Native Bionic binary** — runs directly, no proot or chroot required
- **`bunx` works** — dedicated launcher using `exec -a "bunx"` for proper argv[0]
- **SELinux EACCES fixes** — source-level patches + LD_PRELOAD shim
- **Network auto-fix** — `bun-fix-network` for APAC carrier DNS blocks
- **Cross-compiled from source** — patches applied at build time, not runtime

---

## 📦 Installation

### Quick install (recommended)

```bash
# 1. Download the latest .deb from Releases page
#    https://github.com/bd-loser/bun-termux/releases/latest

# 2. Install
dpkg -i bun_1.3.14-patched_aarch64.deb

# 3. (Optional) Fix network if bun install fails with ConnectionRefused
bun-fix-network
```

### One-liner

```bash
curl -fsSL https://github.com/bd-loser/bun-termux/releases/latest/download/bun_1.3.14-patched_aarch64.deb -o ~/bun.deb && dpkg -i ~/bun.deb && rm ~/bun.deb
```

### From source (advanced)

```bash
git clone https://github.com/bd-loser/bun-termux.git
cd bun-termux
make deb PKGVER=1.3.14
dpkg -i dist/bun_1.3.14-patched_aarch64.deb
```

### pacman (Arch-style)

```bash
pacman -U bun-1.3.14-1-aarch64.pkg.tar.xz
```

---

## 🚀 Usage

```bash
bun --version              # → 1.3.14
bun install                # install dependencies
bun run index.ts           # run a script
bunx prettier --version    # → 3.9.4 (bunx works!)
bunx create-vite my-app    # scaffold a new project
```

---

## ⚠️ Important: Remove stale `bunx` first

If you previously installed Bun via the official installer (`curl https://bun.sh/install | bash`), remove its `bunx` so it doesn't shadow this one:

```bash
rm -f ~/.bun/bin/bunx ~/.bun/bin/bun   # remove old install
hash -r                                # refresh shell's command cache
which bunx                             # should print /data/data/com.termux/files/usr/bin/bunx
```

If you see `CouldntReadCurrentDirectory` after install, this is almost always the cause — `postinst` will warn you about it automatically.

---

## 🔧 How it works

### The SELinux problem

Bun's directory resolver walks UP from the cwd to `/` and tries `opendir()` on every ancestor. On Android, `/` and `/data` are mode `0771` (system:system), so `opendir()` returns `EACCES` and the walk aborts — even though the cwd itself is fully readable.

This affected `bunx` most because it's the only command that calls `configureEnvForRun` with the linker enabled, triggering the directory walk.

### The fix: hybrid (source patches + LD_PRELOAD shim)

Two complementary fix layers are needed because Bun uses **two different syscall paths**:

**1. Source patches** (for the resolver walk)
Bun's directory resolver uses `std.fs.openDirAbsoluteZ` → Zig's `std.os.linux.openat` — a **raw syscall** (inline asm, NOT libc). LD_PRELOAD shims can ONLY intercept libc function calls, not raw syscalls. Therefore source patches are required:

- `resolver.zig Layer 1a`: `AccessDenied => continue` instead of `return null` in the processing loop — skips inaccessible ancestors (/, /data) while still processing accessible ones. **Ancestor walking is PRESERVED** (monorepo support works!)
- `resolver.zig Layer 1b`: DirEntry cache `.err` branch doesn't return `AccessDenied` — prevents cached EACCES on "/" from propagating on subsequent walks, bypassing Layer 1a
- `run_command.zig Layer 2`: synthesize minimal `DirInfo` when `readDirInfo` returns null — final fallback

**2. LD_PRELOAD shim** (for libc calls)
`libbun-android-fix.so` intercepts libc-level calls that the source patches can't reach:

| Interceptor | What it fixes |
|-------------|---------------|
| `linkat`/`symlinkat`/`renameat` | Copy-on-EACCES fallback (`bun install`) |
| `fopen`/`fopen64` | Redirect `/etc/resolv.conf` → `$PREFIX/etc/` (DNS) |
| `mkdir`/`symlink` | Translate `/tmp` → `$TMPDIR` (`bun --bun`) |
| `execve` | Shebang translation `/usr/bin/` → `$PREFIX/bin/` |
| `getcwd` | Fallback to `/proc/self/cwd` or `$PWD` on EACCES |
| `/proc/stat` fake | `os.cpus()` returns real CPU count (via `memfd_create`) |

**3. `bunx` launcher** (packaging)
- Uses `exec -a "bunx"` to set `argv[0]="bunx"` so Bun's `isBunX()` detection routes to `BunxCommand.exec()`

### The network problem

Bun's c-ares DNS resolver hardcodes `/etc/resolv.conf`, which doesn't exist on Termux (it's at `$PREFIX/etc/resolv.conf`). The shim transparently redirects `fopen("/etc/resolv.conf")` → `$PREFIX/etc/resolv.conf`, so c-ares finds the right file.

If DNS still fails (e.g. APAC carrier blocks UDP/53), `bun-fix-network` routes Bun through a local `tinyproxy` on `127.0.0.1:8888`, which uses Android's `getaddrinfo` (same path `curl` uses).

---

## 🏗️ Architecture

```
$PREFIX/bin/bun                → launcher (LD_PRELOAD shim + exec)
$PREFIX/bin/bunx               → launcher (exec -a "bunx" + shim)
$PREFIX/bin/bun-fix-network    → network fix script
$PREFIX/lib/bun-termux/bun     → Android-native Bun binary (Bionic-linked)
$PREFIX/lib/bun-termux/libbun-android-fix.so
                               → LD_PRELOAD shim (EACCES fallbacks)
```

Supported architectures: `aarch64`, `x86_64`

---

## 🔨 Building from source

```bash
make deb    PKGVER=1.3.14    # build .deb package
make pacman PKGVER=1.3.14    # build .pkg.tar.xz package
```

| Variable | Default | Description |
|----------|---------|-------------|
| `PKGVER` | `1.3.14` | Bun version to package |
| `ARCH`   | `aarch64` | Target architecture (`aarch64` or `x86_64`) |
| `PKGREL` | `1` | pacman release number |

For source-patched builds (with all SELinux fixes applied at the Zig source level), use the `Build Bun from Source` GitHub Actions workflow — it cross-compiles with NDK r27c and publishes a release automatically.

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

To disable temporarily:

```bash
HTTP_PROXY= HTTPS_PROXY= bun install
```

</details>

<details>
<summary><b>Monorepo: enclosing package.json not found</b></summary>

**Fixed!** The source patches use `AccessDenied => continue` (Layer 1a) which skips inaccessible ancestors (/, /data) while still processing accessible ones. This means ancestor walking is **preserved** — Bun finds enclosing `package.json` from parent directories normally.

If you still see issues, verify the patches were applied:
```bash
# Check that root_path is ORIGINAL (path[0..1]) — not changed to path
strings $(which bun) | grep -c "ANDROID_TERMUX_FIX"
# Should be > 0
```

</details>

<details>
<summary><b>Native module install fails (e.g. node-gyp, esbuild)</b></summary>

Some npm packages with native C/C++ code fail to install on Android because Bun's installer doesn't detect the platform correctly. Add `BUN_OPTIONS="--os=android"`:

```bash
BUN_OPTIONS="--os=android" bun install
```

For verbose install logs (helps diagnose native module issues):

```bash
BUN_OPTIONS="--os=android --verbose" bun install
```

</details>

<details>
<summary><b>os.cpus() returns empty array</b></summary>

Android SELinux blocks reads of `/proc/stat`. Our LD_PRELOAD shim (v2+) synthesizes a fake `/proc/stat` via `memfd_create` so `os.cpus()` returns the real CPU count. If you're seeing `[]`:

1. Verify the shim is loaded: `BUN_FIX_DEBUG=1 bun -e 'console.log(process.env)' | grep bun-fix`
2. Update to the latest build — `/proc/stat` faking was added in the v2 shim (commit `feat(shim): port Happ1ness patterns`)

</details>

<details>
<summary><b>DNS lookup fails (ENOTFOUND)</b></summary>

The shim transparently redirects `/etc/resolv.conf`, `/etc/nsswitch.conf`, and `/etc/hosts` to `$PREFIX/etc/`. If DNS still fails:

```bash
# Check if resolv.conf exists in Termux prefix
ls -la $PREFIX/etc/resolv.conf

# If missing, install resolv-conf
pkg install resolv-conf

# Or create manually
echo "nameserver 8.8.8.8" > $PREFIX/etc/resolv.conf
```

</details>

<details>
<summary><b>#!shebang scripts fail with "No such file or directory"</b></summary>

The shim translates `#!/usr/bin/env node` and similar shebangs to `$PREFIX/bin/env node`. If a script still fails:

```bash
# Check the shebang
head -1 problematic_script.js

# Use termux-fix-shebang for non-Bun-executed scripts
termux-fix-shebang problematic_script.js
```

</details>

<details>
<summary><b>bun build --compile output doesn't run</b></summary>

`bun build --compile` on Bionic Bun 1.3.14 has known issues with RELRO segment layout. If your compiled binary fails to start:

```bash
# Check if RELRO is the issue
llvm-readelf -lW your-compiled-binary | grep GNU_RELRO
```

If `GNU_RELRO` is present, the compiled binary may not run on Android. This is a Bun upstream issue (not a Termux packaging issue). Track it at [oven-sh/bun#issues](https://github.com/oven-sh/bun/issues).

For now, use `bun build --target=bun` (non-compiled) as a workaround.

</details>

---

## 🙏 Credits

This project builds on the work of several people:

- **[Hope2333/bun-termux](https://github.com/Hope2333/bun-termux)** — upstream fork source, original packaging structure and network fix concept
- **[Happ1ness-dev/bun-termux](https://github.com/Happ1ness-dev/bun-termux)** — several LD_PRELOAD shim patterns adapted into our `libbun-android-fix.c`:
  - `safe_dir_fd` duplicate for `O_DIRECTORY` ancestor opens (fixes project root walk)
  - `/proc/stat` faking via `memfd_create` (fixes `os.cpus()`)
  - `fopen` redirect for `/etc/resolv.conf` → `$PREFIX/etc/` (fixes DNS)
  - `mkdir`/`symlink` translation of `/tmp` → `$TMPDIR` (fixes `bun --bun`)
  - `execve` shebang translation `/usr/bin/` → `$PREFIX/bin/`
  - `__OPEN_NEEDS_MODE` for correct `O_TMPFILE` mode extraction
- **[kaan-escober/bun-termux-loader](https://github.com/kaan-escober/bun-termux-loader)** — original userland-exec technique (Happ1ness's base)
- **[oven-sh/bun](https://github.com/oven-sh/bun)** — the Bun runtime itself, by Jarred Sumner and contributors
- **[opencode-termux](https://github.com/Hope2333/opencode-termux)** — related Termux packaging work

**This fork adds:**
- Source patches (resolver.zig, run_command.zig) — fix the directory resolver walk (raw syscalls)
- `libbun-android-fix.so` LD_PRELOAD shim — fix libc-level calls (linkat, fopen, /proc/stat, etc.)
- `bunx` launcher using `exec -a "bunx"` for proper `isBunX()` detection
- Build patches for NDK clang 18 cross-compilation
- Bionic-native (no glibc-runner, no userland exec) — runs directly via `/system/bin/linker64`

Developed with AI assistance for deep source-code analysis of the Bun runtime.

---

## 📄 License

MIT — see [LICENSE](LICENSE)

<div align="center">

**[Report Bug](../../issues)** · **[Request Feature](../../issues)** · **[Releases](../../releases)**

</div>
