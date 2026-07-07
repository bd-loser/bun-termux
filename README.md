# Bun for Termux

Native Android Bun runtime packaged for Termux. **No glibc, no wrapper, no grun.**

Starting from Bun v1.3.14, official Android builds are available as
Bionic-linked PIE executables that run directly on Termux via
`/system/bin/linker64` — zero extra dependencies.

This fork adds an **automatic network-fix script** (`bun-fix-network`) that
solves the `ConnectionRefused` errors many APAC users hit when running
`bun install` on carrier networks that block public DNS resolvers.

## Installation

### From a release (recommended)

Download the latest `.deb` from [Releases](../../releases), then:

```bash
dpkg -i bun_1.3.14_aarch64.deb
```

After install, if `bun install` fails with `ConnectionRefused`, just run:

```bash
bun-fix-network
```

The fix script will:
1. Install + configure `tinyproxy` on `127.0.0.1:8888`
2. Add `HTTPS_PROXY` / `HTTP_PROXY` to your `~/.bashrc`
3. Auto-start tinyproxy on every new Termux session

After running it once, `source ~/.bashrc` (or open a new session) and `bun install` will work.

### From source

```bash
git clone https://github.com/bd-loser/bun-termux.git
cd bun-termux
make deb PKGVER=1.3.14
dpkg -i dist/bun_1.3.14_aarch64.deb
```

### pacman (Arch-style)

```bash
pacman -U bun-1.3.14-1-aarch64.pkg.tar.xz
```

## Usage

```bash
bun --version
bun run script.ts
bun install
bunx prettier --version     # bunx works! (see note below)
```

## bunx — the missing piece (IMPORTANT)

Bun detects `bunx` mode by checking if `argv[0]` **ends with the string
`"bunx"`** (see `src/cli/cli.zig`, function `isBunX()`). A plain symlink
or `exec bun` would set `argv[0]` to the binary path (ending in `"bun"`),
failing this check — so `bunx` would either not exist as a command or
would fall through to an unpatched `~/.bun/bin/bunx` left over from
`curl https://bun.sh/install | bash`.

This package installs a dedicated `bunx` launcher at
`$PREFIX/bin/bunx` that uses the bash builtin **`exec -a "bunx"`** to
set `argv[0]="bunx"` while still executing the patched Bun binary.
The launcher also loads the `libbun-android-fix.so` LD_PRELOAD shim,
matching the behavior of the `bun` launcher.

### If you see `CouldntReadCurrentDirectory` after install

You almost certainly have a stale, unpatched `bunx` earlier in your
`PATH` (typically `~/.bun/bin/bunx` from the official Bun installer).
The `postinst` script detects this and warns. To fix:

```bash
# Option 1: remove the conflicting bunx
rm ~/.bun/bin/bunx

# Option 2: ensure Termux's bin comes first in PATH
echo 'export PATH=$PREFIX/bin:$PATH' >> ~/.bashrc
source ~/.bashrc

# Verify the RIGHT bunx is being used
which bunx
# Should print: /data/data/com.termux/files/usr/bin/bunx
```

### `bun x` as an alternative

`bun x <package>` is equivalent to `bunx <package>` — both route to
`BunxCommand.exec()`. If you cannot install the `bunx` launcher for
some reason, `bun x` works as a fallback (the `bun` launcher sets
`argv[0]` to the binary path, but Bun's `RootCommandMatcher.case("x")`
routes to `BunxCommand` for the `x` subcommand).

## Why the network fix?

Bun's built-in DNS resolver (c-ares, written in Zig) hardcodes the path
`/etc/resolv.conf`. On Termux this file does **not** exist — Termux keeps it
at `$PREFIX/etc/resolv.conf`. When Bun can't find it, it falls back to
`8.8.8.8` and `1.1.1.1`, which are **actively blocked** on many APAC mobile
carriers (UDP/53 refused → `ConnectionRefused`).

Symptoms:
- `curl https://registry.npmjs.org` works (uses Android's Bionic resolver)
- `bun install` fails with `ConnectionRefused downloading package manifest ...`
- `termux-chroot` does **not** fix it
- glibc / proot does **not** fix it (the resolver is inside the Bun binary)

The fix routes Bun through a local `tinyproxy` on `127.0.0.1:8888`. The
proxy uses Android's `getaddrinfo` (same path `curl` uses), so DNS resolves
correctly and Bun never touches the broken path.

### Disabling the proxy

If you ever need to disable the proxy temporarily (e.g., another tool
misbehaves with it set):

```bash
HTTP_PROXY= HTTPS_PROXY= <command>
```

To remove the fix entirely:

```bash
pkill tinyproxy
sed -i '/bun-fix-network begin/,/bun-fix-network end/d' ~/.bashrc
```

## Architecture

```
/usr/bin/bun                → launcher shell script (loads LD_PRELOAD shim)
/usr/bin/bunx               → launcher shell script (exec -a "bunx" + shim)
/usr/bin/bun-fix-network    → network fix script
/usr/lib/bun-termux/bun     → Android-native Bun binary (Bionic-linked)
                              interpreter: /system/bin/linker64
                              No glibc, no grun, no wrapper
/usr/lib/bun-termux/libbun-android-fix.so
                            → LD_PRELOAD shim (EACCES fallbacks for
                              linkat/symlinkat/openat/renameat)
```

Supported architectures: `aarch64`, `x86_64`

## Building

```bash
make deb    PKGVER=1.3.14 PKGMGR=deb
make pacman PKGVER=1.3.14 PKGMGR=pacman
```

Variables:
- `PKGVER`  — Bun version to package (default: 1.3.14, the latest)
- `ARCH`    — `aarch64` (default) or `x86_64`
- `PKGREL`  — pacman release number (default: 1)

## How it works

Bun v1.3.14+ ships official Android builds. This repo downloads the
appropriate zip from GitHub releases, extracts the binary, and packages
it for Termux's package managers — plus installs the network-fix helper.

## Related

- [Hope2333/bun-termux](https://github.com/Hope2333/bun-termux) — upstream fork source
- [oven-sh/bun](https://github.com/oven-sh/bun) — upstream Bun
- [opencode-termux](https://github.com/Hope2333/opencode-termux) — OpenCode for Termux

## License

MIT
