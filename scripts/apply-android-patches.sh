#!/usr/bin/env bash
# apply-android-patches.sh — Bun v1.4.x Android/Termux source patches
# Android seccomp traps blocked syscalls with SIGSYS, so syscall fallbacks
# must be selected at compile time rather than after ENOSYS/EPERM.
set -euo pipefail

PATCH_MARKER="ANDROID_TERMUX_FIX"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUN_SRC="${BUN_SRC:-${GITHUB_WORKSPACE:-$PWD}}"

if [ ! -f "$BUN_SRC/package.json" ]; then
    echo "FATAL: $BUN_SRC does not look like a bun checkout (no package.json)" >&2
    exit 1
fi
cd "$BUN_SRC"

BUN_VERSION="$(python3 -c 'import json;print(json.load(open("package.json")).get("version","?"))' 2>/dev/null || echo '?')"
echo "Applying Android/Termux patches to Bun $BUN_VERSION"
echo "Source tree: $BUN_SRC"
echo ""

TOTAL_FAIL=0

verify_patch() {
    # verify_patch <file> — checks the patch marker landed in the file
    local f="$1"
    if grep -q "$PATCH_MARKER" "$f" 2>/dev/null; then
        echo "  [OK]   $f"
    else
        echo "  [FAIL] $f — no markers found"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
}

# Runs exact-anchor patchers; every snippet must assert its anchors.
py_patch() {
    python3 -
}

# PATCH 1: scripts/build/config.ts — enable TinyCC on Android
# Upstream disables TinyCC on Android ("oven-sh/tinycc has no bionic
# support"), but our repo carries real fixes against Bun's pinned TinyCC
# commit (patches/tinycc/*.patch): memfd_create W+X mapping (SELinux-safe)
# and arm64 long-call veneers. With those, libtcc builds and links on
# Bionic, enabling bun:ffi cc()/JSCallback.
CONFIG_TS="scripts/build/config.ts"
if [ -f "$CONFIG_TS" ] && ! grep -q "$PATCH_MARKER" "$CONFIG_TS"; then
    echo "[PATCH 1] $CONFIG_TS — enable TinyCC on Android"
    py_patch <<'PYEOF'
import pathlib

p = pathlib.Path("scripts/build/config.ts")
c = p.read_text()

old = 'const tinycc = partial.tinycc ?? !(abi === "android" || freebsd);'
new = ('const tinycc = partial.tinycc ?? !freebsd; '
       '// ANDROID_TERMUX_FIX: enable TinyCC on Android (see patches/tinycc/)')

assert c.count(old) == 1, "config.ts anchor not found (or ambiguous): tinycc gate"
c = c.replace(old, new, 1)
p.write_text(c)
print("  patched tinycc gate")
PYEOF
    verify_patch "$CONFIG_TS"
elif [ -f "$CONFIG_TS" ]; then
    echo "[SKIP 1] $CONFIG_TS already patched"
fi

# PATCH 1b: enable TinyCC at the Rust level
# The generated ENABLE_TINYCC value and libtcc extern cfg must match config.ts.
GATE_TS="scripts/build/buildOptionsRs.ts"
if [ -f "$GATE_TS" ] && ! grep -q "$PATCH_MARKER" "$GATE_TS"; then
    echo "[PATCH 1b] $GATE_TS + src/tcc_sys/tcc.rs — un-gate TinyCC on Android"
    py_patch <<'PYEOF'
import pathlib

p = pathlib.Path("scripts/build/buildOptionsRs.ts")
c = p.read_text()

old = '''    "pub const ENABLE_TINYCC: bool = !cfg!(any(",
    `    target_os = "android",`,
    `    target_os = "freebsd",`,
    "));",'''
new = '''    "pub const ENABLE_TINYCC: bool = !cfg!(any(",
    // ANDROID_TERMUX_FIX_TINYCC_GATE: TinyCC IS built on Android here
    // (config.ts gate flipped; see patches/tinycc/). Only FreeBSD stays out.
    `    target_os = "freebsd",`,
    "));",'''
assert c.count(old) == 1, "buildOptionsRs.ts anchor not found (or ambiguous): ENABLE_TINYCC"
c = c.replace(old, new, 1)
p.write_text(c)

p2 = pathlib.Path("src/tcc_sys/tcc.rs")
c2 = p2.read_text()
subs = [
    ('#[cfg(not(any(target_os = "android", target_os = "freebsd")))]',
     '#[cfg(not(target_os = "freebsd"))] // ANDROID_TERMUX_FIX_TINYCC_GATE'),
    ('#[cfg(any(target_os = "android", target_os = "freebsd"))]',
     '#[cfg(target_os = "freebsd")] // ANDROID_TERMUX_FIX_TINYCC_GATE'),
]
for old2, new2 in subs:
    assert c2.count(old2) == 1, f"tcc_sys/tcc.rs anchor not found (or ambiguous): {old2}"
    c2 = c2.replace(old2, new2, 1)
p2.write_text(c2)
print("  ENABLE_TINYCC now true on android; libtcc externs no longer stubbed")
PYEOF
    verify_patch "$GATE_TS"
elif [ -f "$GATE_TS" ]; then
    echo "[SKIP 1b] $GATE_TS already patched"
fi

# PATCH 2: scripts/build/deps/tinycc.ts — Android defines + patch wiring
# 2a: wire our TinyCC source patches into the dependency's patches array.
# 2b: CONFIG_SELINUX=1 makes tccrun.c allocate executable memory via
#     memfd/mmap instead of rw->rx mprotect on heap memory, which Android's
#     SELinux policy blocks. This is what makes JSCallback work.
TINYCC_TS="scripts/build/deps/tinycc.ts"
if [ -f "$TINYCC_TS" ] && ! grep -q "$PATCH_MARKER" "$TINYCC_TS"; then
    echo "[PATCH 2] $TINYCC_TS — Android defines + patch wiring"
    py_patch <<'PYEOF'
import pathlib

p = pathlib.Path("scripts/build/deps/tinycc.ts")
c = p.read_text()

old_patches = 'patches: ["patches/tinycc/tcc.h.patch"],'
new_patches = ('patches: [\n'
               '      // ANDROID_TERMUX_FIX: memfd_create W+X mapping (SELinux-safe)\n'
               '      // + arm64 linker veneers for far branches. Required to build\n'
               '      // libtcc against Bionic and run JIT memory on Android.\n'
               '      "patches/tinycc/tccrun.c.patch",\n'
               '      "patches/tinycc/arm64-link.c.patch",\n'
               '    ],')
assert c.count(old_patches) == 1, "tinycc.ts anchor not found: patches array"
c = c.replace(old_patches, new_patches, 1)

old_def = "if (cfg.windows) defines.CONFIG_WIN32 = true;"
new_def = old_def + """

    // ANDROID_TERMUX_FIX: Android SELinux blocks mprotect(PROT_EXEC) on heap
    // memory; CONFIG_SELINUX=1 switches tcc to tmpfile/memfd-backed
    // executable mappings, which is what keeps bun:ffi JSCallback working.
    if (!cfg.darwin && !cfg.windows && cfg.abi === "android") {
      defines.CONFIG_SELINUX = 1;
    }"""
assert c.count(old_def) == 1, "tinycc.ts anchor not found: CONFIG_WIN32 define"
c = c.replace(old_def, new_def, 1)

p.write_text(c)
print("  wired tccrun/arm64-link patches + CONFIG_SELINUX")
PYEOF
    verify_patch "$TINYCC_TS"
elif [ -f "$TINYCC_TS" ]; then
    echo "[SKIP 2] $TINYCC_TS already patched"
fi

# tinycc.ts resolves patch paths from the Bun checkout.
for tpf in tccrun.c.patch arm64-link.c.patch; do
    SRC="$REPO_DIR/patches/tinycc/$tpf"
    DST="$BUN_SRC/patches/tinycc/$tpf"
    if [ ! -f "$SRC" ]; then
        echo "  [FAIL] missing required file in bun-termux repo: patches/tinycc/$tpf"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        continue
    fi
    mkdir -p "$BUN_SRC/patches/tinycc"
    if cmp -s "$SRC" "$DST" 2>/dev/null; then
        echo "  [OK]   patches/tinycc/$tpf already current in bun tree"
    else
        cp "$SRC" "$DST"
        echo "  [OK]   copied patches/tinycc/$tpf into bun tree"
    fi
done

# PATCH 2b: scripts/build/fetch-cli.ts — dep patches apply inside git repos
# Upstream's applyPatch() runs `git apply --no-index -` with cwd=vendor/<dep>.
# Documented git behavior: when the destination lives INSIDE a repository
# (the bun checkout always is), git apply resolves the patch's target paths
# relative to the REPO ROOT, not cwd. Result: git apply writes stray files at
# the checkout root, exits 0, fetch stamps .ref, and vendor/tinycc stays
# pristine — every dep patch silently no-ops. GNU patch with -d <dir> is
# always dir-relative, so use it instead.
FETCH_TS="scripts/build/fetch-cli.ts"
if [ -f "$FETCH_TS" ] && ! grep -q "ANDROID_TERMUX_FIX_APPLY_PATCH" "$FETCH_TS"; then
    echo "[PATCH 2b] $FETCH_TS — applyPatch: git apply -> patch -p1 -d"
    py_patch <<'PYEOF'
import pathlib

p = pathlib.Path("scripts/build/fetch-cli.ts")
c = p.read_text()

old = '''  const result = spawnSync("git", ["apply", "--ignore-whitespace", "--ignore-space-change", "--no-index", "-"], {
    cwd: dest,
    input: normalizeLf(patchBody),
    stdio: ["pipe", "ignore", "pipe"],
    encoding: "utf8",
  });'''

new = '''  // ANDROID_TERMUX_FIX_APPLY_PATCH: `git apply --no-index` resolves paths
  // against the enclosing repo root when dest is inside one, silently
  // applying nothing while exiting 0. GNU patch with -d is dir-relative.
  const result = spawnSync(
    "patch",
    ["-p1", "--forward", "--no-backup-if-mismatch", "--silent", "-d", dest],
    {
      input: normalizeLf(patchBody),
      stdio: ["pipe", "ignore", "pipe"],
      encoding: "utf8",
    },
  );'''

assert c.count(old) == 1, "fetch-cli.ts anchor not found (or ambiguous): applyPatch spawnSync"
c = c.replace(old, new, 1)
p.write_text(c)
print("  applyPatch now uses patch(1); repo-root escape closed")
PYEOF
    verify_patch "$FETCH_TS"
elif [ -f "$FETCH_TS" ]; then
    echo "[SKIP 2b] $FETCH_TS already patched"
fi

# PATCH 3: scripts/build/tools.ts — accept NDK-era clang (LLVM 18)
# Bun's C/C++ deps are cross-built by the HOST clang driving --target against
# the NDK sysroot, so discovery must accept whatever clang the runner ships.
# ubuntu-latest provides clang 18.1.x; upstream hard-requires 21.1.x. Relax
# the pinned version and widen the acceptance range to the whole 18 major.
TOOLS_TS="scripts/build/tools.ts"
if [ -f "$TOOLS_TS" ] && ! grep -q "$PATCH_MARKER" "$TOOLS_TS"; then
    echo "[PATCH 3] $TOOLS_TS — accept host clang 18.x"
    py_patch <<'PYEOF'
import pathlib

p = pathlib.Path("scripts/build/tools.ts")
c = p.read_text()

subs = [
    ('export const LLVM_VERSION = "21.1.8";',
     'export const LLVM_VERSION = "18.1.3"; // ANDROID_TERMUX_FIX: host clang'),
    ('const LLVM_MAJOR = "21";',
     'const LLVM_MAJOR = "18"; // ANDROID_TERMUX_FIX'),
    ('const LLVM_VERSION_RANGE = `>=${LLVM_MAJOR}.${LLVM_MINOR}.0 <${LLVM_MAJOR}.${LLVM_MINOR}.99`;',
     '// ANDROID_TERMUX_FIX: accept any 18.x — distros ship varying minors\n'
     'const LLVM_VERSION_RANGE = `>=${LLVM_MAJOR}.0.0 <${Number(LLVM_MAJOR) + 1}.0.0`;'),
]
for old, new in subs:
    assert c.count(old) == 1, f"tools.ts anchor not found (or ambiguous): {old}"
    c = c.replace(old, new, 1)

p.write_text(c)
print("  relaxed LLVM requirement to any 18.x")
PYEOF
    verify_patch "$TOOLS_TS"
elif [ -f "$TOOLS_TS" ]; then
    echo "[SKIP 3] $TOOLS_TS already patched"
fi

# PATCH 3b: scripts/build/flags.ts — drop clang-19+ warning flag
# Upstream suppresses -Wcharacter-conversion, a diagnostic added in clang
# 19. Host clang 18 treats the unknown -Wno- option as an error under
# -Werror=-Wunknown-warning-option and the PCH step dies.
FLAGS_TS="scripts/build/flags.ts"
if [ -f "$FLAGS_TS" ] && ! grep -q "ANDROID_TERMUX_FIX_NO_CHARCONV" "$FLAGS_TS"; then
    echo "[PATCH 3b] $FLAGS_TS — remove -Wno-character-conversion"
    py_patch <<'PYEOF'
import pathlib

p = pathlib.Path("scripts/build/flags.ts")
c = p.read_text()

old = """      "-Wno-nullability-completeness",
      "-Wno-character-conversion",
      "-Werror","""
new = """      "-Wno-nullability-completeness",
      // ANDROID_TERMUX_FIX_NO_CHARCONV: clang 18 doesn't know
      // -Wcharacter-conversion (added in clang 19); under -Werror the
      // unknown -Wno- form kills the build.
      "-Werror","""

assert c.count(old) == 1, "flags.ts anchor not found (or ambiguous): unix Werror block"
c = c.replace(old, new, 1)

p.write_text(c)
print("  removed clang-19-only flag from unix block")
PYEOF
    verify_patch "$FLAGS_TS"
elif [ -f "$FLAGS_TS" ]; then
    echo "[SKIP 3b] $FLAGS_TS already patched"
fi

# PATCH 3c: C++ dangling-reference fix for clang 18
# BunTestModule.h binds a range-for directly over a temporary's member
# (properties.releaseData()->propertyNameVector()). Upstream builds with
# clang 21 where -Wdangling tolerates this; host clang 18 errors under
# -Werror (-Wdangling). Hoist the owner to a local first.
echo "[PATCH 3c] src/** — hoist releaseData() temporary out of range-for"
if grep -rq "ANDROID_TERMUX_FIX_DANGLING" "$BUN_SRC/src" 2>/dev/null; then
    echo "  [SKIP] already patched"
else
py_patch <<'PYEOF'
import pathlib
import re

pat = re.compile(
    r"for \(auto& (\w+) : properties\.releaseData\(\)->propertyNameVector\(\)\)"
)

patched = 0
for p in pathlib.Path("src").rglob("*"):
    if p.suffix not in (".cpp", ".h", ".mm") or not p.is_file():
        continue
    t = p.read_text()
    if "properties.releaseData()->propertyNameVector()" not in t:
        continue
    new = pat.sub(
        lambda m: (
            "auto _termux_release_data = properties.releaseData(); "
            f"for (auto& {m.group(1)} : _termux_release_data->propertyNameVector())"
            " /* ANDROID_TERMUX_FIX_DANGLING */"
        ),
        t,
    )
    p.write_text(new)
    patched += 1

assert patched >= 1, "no dangling-reference sites found — upstream changed?"
print(f"  patched {patched} file(s) with dangling-reference fix")
PYEOF
fi

# PATCH 4: src/sys/lib.rs — lchmod without fchmodat2
# Upstream implements lchmod via the fchmodat2(452) syscall with a runtime
# ENOSYS fallback to fchmodat(AT_SYMLINK_NOFOLLOW). On Android the zygote
# seccomp filter TRAPS fchmodat2 (SIGSYS, no errno), so every symlink-mode
# change kills the process instead of falling back. Compile-time switch.
SYS_LIB_RS="src/sys/lib.rs"
if [ -f "$SYS_LIB_RS" ] && ! grep -q "ANDROID_TERMUX_FIX_LCHMOD" "$SYS_LIB_RS"; then
    echo "[PATCH 4] $SYS_LIB_RS — lchmod: avoid trapped fchmodat2"
    py_patch <<'PYEOF'
import pathlib

p = pathlib.Path("src/sys/lib.rs")
c = p.read_text()

old = """        #[cfg(not(any(target_os = "macos", target_os = "freebsd")))]
        {
            const SYS_FCHMODAT2: libc::c_long = 452;
            loop {
                // SAFETY: `ZStr::as_ptr()` yields a valid NUL-terminated C string.
                let rc = unsafe {
                    libc::syscall(
                        SYS_FCHMODAT2,
                        Fd::cwd().native() as libc::c_long,
                        path.as_ptr(),
                        mode as libc::c_long,
                        libc::AT_SYMLINK_NOFOLLOW as libc::c_long,
                    )
                };
                if rc < 0 {
                    let e = last_errno();
                    if e == libc::EINTR {
                        continue;
                    }
                    if e == libc::ENOSYS {
                        return fchmodat(Fd::cwd(), path, mode, libc::AT_SYMLINK_NOFOLLOW);
                    }
                    return Err(Error::from_code_int(e, Tag::lchmod).with_path(path.as_bytes()));
                }
                return Ok(());
            }
        }"""

new = """        #[cfg(not(any(target_os = "macos", target_os = "freebsd")))]
        {
            // ANDROID_TERMUX_FIX_LCHMOD: Android's zygote seccomp profile
            // returns SECCOMP_RET_TRAP for fchmodat2, raising SIGSYS instead
            // of returning ENOSYS, so upstream's runtime fallback never gets
            // a chance to run. Use fchmodat(AT_SYMLINK_NOFOLLOW) directly.
            #[cfg(target_os = "android")]
            {
                return fchmodat(Fd::cwd(), path, mode, libc::AT_SYMLINK_NOFOLLOW);
            }

            #[cfg(not(target_os = "android"))]
            {
                const SYS_FCHMODAT2: libc::c_long = 452;
                loop {
                    // SAFETY: `ZStr::as_ptr()` yields a valid NUL-terminated C string.
                    let rc = unsafe {
                        libc::syscall(
                            SYS_FCHMODAT2,
                            Fd::cwd().native() as libc::c_long,
                            path.as_ptr(),
                            mode as libc::c_long,
                            libc::AT_SYMLINK_NOFOLLOW as libc::c_long,
                        )
                    };
                    if rc < 0 {
                        let e = last_errno();
                        if e == libc::EINTR {
                            continue;
                        }
                        if e == libc::ENOSYS {
                            return fchmodat(Fd::cwd(), path, mode, libc::AT_SYMLINK_NOFOLLOW);
                        }
                        return Err(Error::from_code_int(e, Tag::lchmod).with_path(path.as_bytes()));
                    }
                    return Ok(());
                }
            }
        }"""

assert c.count(old) == 1, "sys/lib.rs anchor not found (or ambiguous): lchmod block"
c = c.replace(old, new, 1)
p.write_text(c)
print("  split lchmod into android (fchmodat) / other (fchmodat2)")
PYEOF
    verify_patch "$SYS_LIB_RS"
elif [ -f "$SYS_LIB_RS" ]; then
    echo "[SKIP 4] $SYS_LIB_RS already patched"
fi

# PATCH 5: src/sys/linux_syscall.rs — openat2 fallback
# Same seccomp story as fchmodat2: RESOLVE_BENEATH / RESOLVE_IN_ROOT walks
# go through openat2(437), which Android traps outright. Route Android to
# plain openat. We lose kernel-enforced symlink confinement; acceptable on
# Termux where the threat model doesn't include hostile root dirs.
LSC_RS="src/sys/linux_syscall.rs"
if [ -f "$LSC_RS" ] && ! grep -q "ANDROID_TERMUX_FIX_OPENAT2" "$LSC_RS"; then
    echo "[PATCH 5] $LSC_RS — openat2: compile-time openat fallback"
    py_patch <<'PYEOF'
import pathlib

p = pathlib.Path("src/sys/linux_syscall.rs")
c = p.read_text()

beneath_old = """    retry(|| {
        rustix::fs::openat2(
            dir,
            path.as_cstr(),
            oflags,
            mode,
            rustix::fs::ResolveFlags::BENEATH,
        )
    })
    .map(own_fd)"""

beneath_new = """    retry(|| {
        // ANDROID_TERMUX_FIX_OPENAT2: seccomp traps openat2 on Android
        // (SECCOMP_RET_TRAP, not ENOSYS), so the walk must not use it.
        // Plain openat loses RESOLVE_BENEATH confinement; fine on Termux.
        #[cfg(target_os = "android")]
        {
            rustix::fs::openat(dir, path.as_cstr(), oflags, mode)
        }
        #[cfg(not(target_os = "android"))]
        {
            rustix::fs::openat2(
                dir,
                path.as_cstr(),
                oflags,
                mode,
                rustix::fs::ResolveFlags::BENEATH,
            )
        }
    })
    .map(own_fd)"""

inroot_old = """    retry(|| {
        rustix::fs::openat2(
            dir,
            path.as_cstr(),
            oflags,
            mode,
            rustix::fs::ResolveFlags::IN_ROOT | rustix::fs::ResolveFlags::NO_MAGICLINKS,
        )
    })
    .map(own_fd)"""

inroot_new = """    retry(|| {
        // ANDROID_TERMUX_FIX_OPENAT2: see openat2_beneath above. IN_ROOT /
        // NO_MAGICLINKS have no openat equivalent; resolve relative to dirfd.
        #[cfg(target_os = "android")]
        {
            rustix::fs::openat(dir, path.as_cstr(), oflags, mode)
        }
        #[cfg(not(target_os = "android"))]
        {
            rustix::fs::openat2(
                dir,
                path.as_cstr(),
                oflags,
                mode,
                rustix::fs::ResolveFlags::IN_ROOT | rustix::fs::ResolveFlags::NO_MAGICLINKS,
            )
        }
    })
    .map(own_fd)"""

assert c.count(beneath_old) == 1, "linux_syscall.rs anchor not found: openat2_beneath"
c = c.replace(beneath_old, beneath_new, 1)
assert c.count(inroot_old) == 1, "linux_syscall.rs anchor not found: openat2_in_root"
c = c.replace(inroot_old, inroot_new, 1)

p.write_text(c)
print("  patched openat2_beneath + openat2_in_root")
PYEOF
    verify_patch "$LSC_RS"
elif [ -f "$LSC_RS" ]; then
    echo "[SKIP 5] $LSC_RS already patched"
fi

# PATCH 6: src/spawn_sys/posix_spawn.rs — shebang interpreter remap
# Remap missing FHS shebang interpreters to $PREFIX/bin and rebuild argv.
PS_RS="src/spawn_sys/posix_spawn.rs"
if [ -f "$PS_RS" ] && ! grep -q "ANDROID_TERMUX_FIX_SHEBANG" "$PS_RS"; then
    echo "[PATCH 6] $PS_RS — remap missing-interpreter shebangs"
    py_patch <<'PYEOF'
import pathlib

p = pathlib.Path("src/spawn_sys/posix_spawn.rs")
c = p.read_text()

helper_anchor = """    #[cfg(unix)]
    pub(crate) fn spawn_z(
        path: &CStr,"""

helper = """    /// Remap missing FHS shebang interpreters to $PREFIX/bin on Android.
    #[cfg(target_os = "android")]
    fn android_shebang_remap(script: &CStr) -> Option<CString> {
        const HDR_MAX: usize = 256;
        let mut hdr = [0u8; HDR_MAX];
        // SAFETY: plain fd lifecycle around a fixed-size buffer.
        let fd = unsafe { system::open(script.as_ptr(), system::O_RDONLY | system::O_CLOEXEC) };
        if fd < 0 {
            return None;
        }
        let mut filled = 0usize;
        while filled < HDR_MAX {
            let n = unsafe {
                system::read(fd, hdr[filled..].as_mut_ptr().cast(), HDR_MAX - filled)
            };
            if n <= 0 {
                break;
            }
            filled += n as usize;
        }
        unsafe { system::close(fd) };
        if filled < 3 || hdr[0] != b'#' || hdr[1] != b'!' {
            return None;
        }
        let mut i = 2usize;
        while i < filled && (hdr[i] == b' ' || hdr[i] == b'\\t') {
            i += 1;
        }
        let start = i;
        while i < filled
            && hdr[i] != b'\\n'
            && hdr[i] != b' '
            && hdr[i] != b'\\t'
            && hdr[i] != 0
        {
            i += 1;
        }
        let interp = &hdr[start..i];
        if interp.first() != Some(&b'/') || interp.contains(&0) {
            return None;
        }
        let rest = if let Some(r) = interp.strip_prefix(b"/usr/bin/") {
            r
        } else if let Some(r) = interp.strip_prefix(b"/bin/") {
            r
        } else if let Some(r) = interp.strip_prefix(b"/usr/sbin/") {
            r
        } else if let Some(r) = interp.strip_prefix(b"/sbin/") {
            r
        } else {
            return None;
        };
        let interp_c = CString::new(interp).ok()?;
        // SAFETY: `interp_c` is NUL-terminated for the duration of the call.
        if unsafe { system::access(interp_c.as_ptr(), system::F_OK) } == 0 {
            return None; // interpreter exists; the kernel handles this natively
        }
        // SAFETY: NUL-terminated literal; result is owned by libc.
        let prefix_ptr = unsafe { system::getenv(b"PREFIX\\0".as_ptr().cast()) };
        if prefix_ptr.is_null() {
            return None;
        }
        // SAFETY: getenv results live for the life of the process.
        let prefix = unsafe { core::ffi::CStr::from_ptr(prefix_ptr) }.to_bytes();
        let mut out = Vec::with_capacity(prefix.len() + rest.len() + 5);
        out.extend_from_slice(prefix);
        out.extend_from_slice(b"/bin/");
        out.extend_from_slice(rest);
        CString::new(out).ok()
    }

""" + helper_anchor

assert c.count(helper_anchor) == 1, "posix_spawn.rs anchor not found: spawn_z signature"
c = c.replace(helper_anchor, helper, 1)

hook_anchor = """        let uid = attr.and_then(|a| a.uid);
        let gid = attr.and_then(|a| a.gid);
"""

hook = """        let uid = attr.and_then(|a| a.uid);
        let gid = attr.and_then(|a| a.gid);

        // ANDROID_TERMUX_FIX_SHEBANG: emulate binfmt_script with the remapped interpreter.
        #[cfg(target_os = "android")]
        let (path_storage, argv_storage): (Option<CString>, Option<Vec<*const c_char>>) =
            match android_shebang_remap(path) {
                Some(interp) => {
                    // SAFETY: `argv` is a null-terminated argv array per posix_spawn contract.
                    let argc = unsafe {
                        let mut n = 0usize;
                        while !(*argv.offset(n as isize)).is_null() && n < 4096 {
                            n += 1;
                        }
                        n
                    };
                    let mut new_argv: Vec<*const c_char> = Vec::with_capacity(argc + 2);
                    new_argv.push(interp.as_ptr());
                    new_argv.push(path.as_ptr());
                    unsafe {
                        for j in 1..argc as isize {
                            let entry = *argv.offset(j);
                            if entry.is_null() {
                                break;
                            }
                            new_argv.push(entry);
                        }
                    }
                    new_argv.push(core::ptr::null());
                    (Some(interp), Some(new_argv))
                }
                None => (None, None),
            };
        #[cfg(target_os = "android")]
        let path: &CStr = path_storage.as_deref().unwrap_or(path);
        #[cfg(target_os = "android")]
        let argv: *const *const c_char =
            argv_storage.as_ref().map_or(argv, |v| v.as_ptr());
"""

assert c.count(hook_anchor) == 1, "posix_spawn.rs anchor not found: uid/gid prologue"
c = c.replace(hook_anchor, hook, 1)

p.write_text(c)
print("  added android_shebang_remap + spawn_z hook")
PYEOF
    verify_patch "$PS_RS"
elif [ -f "$PS_RS" ]; then
    echo "[SKIP 6] $PS_RS already patched"
fi

# PATCH 7: src/runtime/ffi/ffi_body.rs — TinyCC search paths for Android
# Upstream probes FHS locations only (/usr/include[aarch64-linux-gnu],
# /usr/lib/aarch64-linux-gnu, /usr/lib64, /usr/local). None exist on Android:
# Bionic libc lives in /system/lib64 and Termux toolchains under $PREFIX.
# Without these paths bun:ffi cc() fails with "library 'c' not found".
FFI_RS="src/runtime/ffi/ffi_body.rs"
if [ -f "$FFI_RS" ] && ! grep -q "ANDROID_TERMUX_FIX_TCC_PATHS" "$FFI_RS"; then
    echo "[PATCH 7] $FFI_RS — TinyCC Android search paths"
    py_patch <<'PYEOF'
import pathlib

p = pathlib.Path("src/runtime/ffi/ffi_body.rs")
c = p.read_text()

anchor = """        #[cfg(any(target_os = "linux", target_os = "android"))]
        {
            if let Some(include_dir) = Self::get_system_include_dir() {"""

block = """        #[cfg(all(target_os = "android", target_arch = "aarch64"))]
        {
            // ANDROID_TERMUX_FIX_TCC_PATHS: give TinyCC the Bionic libc and
            // Termux headers/libs. Upstream probes only FHS directories,
            // none of which exist on Android.
            if dir_exists(b"/system/lib64") {
                if state.add_library_path(zstr!("/system/lib64")).is_err() {
                    bun_output::scoped_log!(TCC, "TinyCC failed to add library path");
                }
            }
            // SAFETY: NUL-terminated literal; result owned by libc.
            let prefix_ptr = unsafe { libc::getenv(b"PREFIX\\0".as_ptr().cast()) };
            if !prefix_ptr.is_null() {
                // SAFETY: getenv strings live for the life of the process.
                let prefix = unsafe { core::ffi::CStr::from_ptr(prefix_ptr) }.to_bytes();
                let targets: [&[u8]; 4] = [
                    b"/include",
                    b"/include/aarch64-linux-android",
                    b"/lib",
                    b"/lib/aarch64-linux-android",
                ];
                for (idx, tail) in targets.iter().enumerate() {
                    let mut joined = Vec::with_capacity(prefix.len() + tail.len());
                    joined.extend_from_slice(prefix);
                    joined.extend_from_slice(tail);
                    let mut buf = [0u8; 512];
                    if joined.len() > 510 {
                        continue;
                    }
                    buf[..joined.len()].copy_from_slice(&joined);
                    buf[joined.len()] = 0;
                    // SAFETY: buf[..len+1] is NUL-terminated by construction.
                    let z = bun_core::ZBox::from_vec_with_nul(
                        buf[..joined.len() + 1].to_vec(),
                    );
                    let res = if idx < 2 {
                        state.add_sys_include_path(&z)
                    } else {
                        state.add_library_path(&z)
                    };
                    if res.is_err() {
                        bun_output::scoped_log!(TCC, "TinyCC failed to add path");
                    }
                }
            }
        }

""" + anchor

assert c.count(anchor) == 1, "ffi_body.rs anchor not found: linux/android sysinclude block"
c = c.replace(anchor, block, 1)

p.write_text(c)
print("  added /system/lib64 + $PREFIX search paths")
PYEOF
    verify_patch "$FFI_RS"
elif [ -f "$FFI_RS" ]; then
    echo "[SKIP 7] $FFI_RS already patched"
fi

# PATCH 8: src/jsc/bindings/c-bindings.cpp — close_range without the syscall
# Android 12's zygote seccomp allowlist predates close_range (436, Linux
# 5.9): the filter TRAPS the syscall (SIGSYS, "Bad system call") before it
# can return ENOSYS, so upstream's best-effort fallbacks never run. This
# kills bun at startup (bun_close_range(4, ~0U, CLOEXEC) runs during
# process init). Android 13+ allows it, which is why only 12 users hit it.
# Walk /proc/self/fd on Android instead of calling the trapped syscall.
CBINDINGS_CPP="src/jsc/bindings/c-bindings.cpp"
if [ -f "$CBINDINGS_CPP" ] && ! grep -q "ANDROID_TERMUX_FIX_CLOSE_RANGE" "$CBINDINGS_CPP"; then
    echo "[PATCH 8] $CBINDINGS_CPP — close_range via /proc/self/fd walk"
    py_patch <<'PYEOF'
import pathlib

p = pathlib.Path("src/jsc/bindings/c-bindings.cpp")
c = p.read_text()

old = """// close_range is glibc > 2.33, which is very new
extern "C" ssize_t bun_close_range(unsigned int start, unsigned int end, unsigned int flags)
{
    return syscall(__NR_close_range, start, end, flags);
}"""

new = """// close_range is glibc > 2.33, which is very new
#if defined(__ANDROID__)
// ANDROID_TERMUX_FIX_CLOSE_RANGE: Android 12's zygote seccomp allowlist
// predates close_range (436). The filter uses SECCOMP_RET_TRAP, so the
// syscall raises SIGSYS before returning ENOSYS and every fallback at the
// call sites is dead code. Walk /proc/self/fd instead — same observable
// behavior, no trap. Returns 0 so callers skip their own fallback loops.
#include <dirent.h>
#include <cerrno>
extern "C" ssize_t bun_close_range(unsigned int start, unsigned int end, unsigned int flags)
{
    DIR* d = opendir("/proc/self/fd");
    if (!d) {
        // /proc unavailable — mimic ENOSYS so the caller's fallback can run.
        errno = ENOSYS;
        return -1;
    }
    int dfd = dirfd(d);
    struct dirent* e;
    const bool cloexec_only = (flags & CLOSE_RANGE_CLOEXEC) != 0;
    while ((e = readdir(d)) != nullptr) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        char* endp = nullptr;
        unsigned long v = strtoul(e->d_name, &endp, 10);
        if (endp == e->d_name || *endp != '\\0') continue;
        if (v > 0x7fffffffUL) continue;
        unsigned int fd = (unsigned int)v;
        if (fd < start || fd > end) continue;
        if ((int)fd == dfd) continue; // don't close the iteration fd
        if (cloexec_only) {
            int fl = fcntl((int)fd, F_GETFD);
            if (fl != -1) fcntl((int)fd, F_SETFD, fl | FD_CLOEXEC);
        } else {
            close((int)fd);
        }
    }
    closedir(d);
    return 0;
}
#else
extern "C" ssize_t bun_close_range(unsigned int start, unsigned int end, unsigned int flags)
{
    return syscall(__NR_close_range, start, end, flags);
}
#endif"""

assert c.count(old) == 1, "c-bindings.cpp anchor not found (or ambiguous): bun_close_range Linux branch"
c = c.replace(old, new, 1)
p.write_text(c)
print("  bun_close_range now walks /proc/self/fd on Android")
PYEOF
    verify_patch "$CBINDINGS_CPP"
elif [ -f "$CBINDINGS_CPP" ]; then
    echo "[SKIP 8] $CBINDINGS_CPP already patched"
fi

echo ""
echo "=========================================="
echo "PATCH VERIFICATION SUMMARY"
echo "=========================================="
FAIL=0
for f in \
    scripts/build/config.ts \
    scripts/build/deps/tinycc.ts \
    scripts/build/tools.ts \
    src/sys/lib.rs \
    src/sys/linux_syscall.rs \
    src/spawn_sys/posix_spawn.rs \
    src/runtime/ffi/ffi_body.rs \
    src/jsc/bindings/c-bindings.cpp; do
    if [ -f "$f" ]; then
        COUNT=$(grep -c "$PATCH_MARKER" "$f" 2>/dev/null || true)
        if [ "${COUNT:-0}" -gt 0 ]; then
            echo "  [OK]   $f ($COUNT markers)"
        else
            echo "  [FAIL] $f — NO MARKERS FOUND"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "  [SKIP] $f — not present in this Bun version"
    fi
done

TOTAL_FAIL=$((TOTAL_FAIL + FAIL))

echo ""
if [ "$TOTAL_FAIL" -gt 0 ]; then
    echo "=========================================="
    echo "FATAL: $TOTAL_FAIL patch(es) did not apply!"
    echo "Refusing to produce a broken Android build."
    echo "=========================================="
    exit 1
fi

echo "=========================================="
echo "All Android/Termux patches applied successfully."
echo "Source-level only: no LD_PRELOAD, no termux-exec."
echo "  - TinyCC enabled on Android (+SELinux-safe JIT, arm64 veneers)"
echo "  - NDK clang 18 accepted"
echo "  - fchmodat2/openat2 seccomp traps bypassed at compile time"
echo "  - missing-interpreter shebangs remapped to \$PREFIX/bin"
echo "  - bun:ffi finds Bionic libc + Termux headers"
echo "=========================================="
