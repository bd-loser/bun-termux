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

### The fix (3 layers)

**Layer 1 — `src/resolver/resolver.zig`** (source patch)
- `root_path = path` (cwd) instead of `path[0..1]` (`/`) — walk never queues inaccessible ancestors
- `AccessDenied => continue` instead of `return null` — skips inaccessible ancestors cleanly

**Layer 2 — `src/cli/run_command.zig`** (source patch)
- When `readDirInfo` returns `null`, synthesize a minimal `DirInfo` from cwd instead of returning `CouldntReadCurrentDirectory`

**Layer 3 — `src/bun.zig`** (source patch)
- `openDirForIteration` / `openDirAbsolute`: on `EACCES`, retry without `O_DIRECTORY`

**Layer 4 — `libbun-android-fix.so`** (LD_PRELOAD shim)
- Intercepts `linkat`/`symlinkat`/`openat`/`renameat` — falls back to copy on EACCES

**Layer 5 — `bunx` launcher** (packaging)
- Uses `exec -a "bunx"` to set `argv[0]="bunx"` so Bun's `isBunX()` detection routes to `BunxCommand.exec()`

### The network problem

Bun's c-ares DNS resolver hardcodes `/etc/resolv.conf`, which doesn't exist on Termux (it's at `$PREFIX/etc/resolv.conf`). When Bun can't find it, it falls back to `8.8.8.8`/`1.1.1.1`, which are blocked on many APAC carriers (UDP/53 refused).

`bun-fix-network` routes Bun through a local `tinyproxy` on `127.0.0.1:8888`, which uses Android's `getaddrinfo` (same path `curl` uses).

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

Layer 1a (`root_path = cwd`) disables ancestor walking, so Bun can't find `package.json` from parent directories. **Workaround**: always run `bun` from the project root, or set `npm_package_name` manually.

This is a known limitation documented in `scripts/apply-android-patches.sh`. Removing Layer 1a and relying on Layer 1b alone would restore ancestor walking, but is riskier.

</details>

---

## 🙏 Credits

This project builds on the work of several people:

- **[Hope2333/bun-termux](https://github.com/Hope2333/bun-termux)** — upstream fork source, original packaging structure and network fix concept
- **[oven-sh/bun](https://github.com/oven-sh/bun)** — the Bun runtime itself, by Jarred Sumner and contributors
- **[opencode-termux](https://github.com/Hope2333/opencode-termux)** — related Termux packaging work

**This fork adds:**
- Source-level SELinux patches (resolver.zig, run_command.zig, bun.zig) — fixing `CouldntReadCurrentDirectory` at the root
- `libbun-android-fix.so` LD_PRELOAD shim for EACCES syscall fallbacks
- `bunx` launcher using `exec -a "bunx"` for proper `isBunX()` detection
- Reworked CI with from-source patched builds

Developed with AI assistance for deep source-code analysis of the Bun runtime.

---

## 📄 License

MIT — see [LICENSE](LICENSE)

<div align="center">

**[Report Bug](../../issues)** · **[Request Feature](../../issues)** · **[Releases](../../releases)**

</div>
