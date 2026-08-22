#!/usr/bin/env bash
# =============================================================================
# apply-android-patches.sh — Bun v1.4.x Android/Termux source patches
#
# Rewritten for the Rust rewrite (Bun 1.4). Replaces the Zig-era script.
#
# What changed vs the 1.3.14 script:
#   - DROPPED (upstream fixed): resolver Layers 1a/1b, cli/run_command.zig,
#     exe_format/elf.zig 4a-4e, StandaloneModuleGraph PIE handling.
#   - DROPPED (obsolete): EncodingTables.h pragma, C++ dangling-ref perl hack,
#     runtime/ffi/ffi.zig (file replaced by src/runtime/ffi/ffi_body.rs),
#     main.zig mallopt, flags.ts -march rewrite (upstream now special-cases
#     Android arm64 itself).
#   - DROPPED (already correct in 1.4): c-bindings.cpp close_range — the Linux
#     branch is already a raw syscall(__NR_close_range) compatible with bionic.
#   - KEPT/PORTED: config.ts TinyCC enable, deps/tinycc.ts defines + patch
#     wiring, tools.ts LLVM relaxation, NEW lchmod/openat2 seccomp fixes,
#     NEW shebang remap, NEW TinyCC Android search paths (ffi_body.rs).
#   - LD_PRELOAD shim is GONE. Everything is source-level now.
#
# Key principle (learned empirically on-device): Android's zygote seccomp
# filter returns SECCOMP_RET_TRAP for blocked syscalls, which raises SIGSYS
# instead of setting errno. Any patch relying on runtime ENOSYS/EPERM
# fallbacks never executes. Every syscall-level fix below is therefore a
# compile-time #[cfg(target_os = "android")] branch.
# =============================================================================
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

# py_patch <python-body-via-stdin> : runs an exact-anchor python patcher.
# Each snippet MUST assert() its anchor; a failed assert aborts the script
# (set -e) so CI fails loudly instead of shipping a half-patched tree.
py_patch() {
    python3 -
}

# =============================================================================
# PATCH 1: scripts/build/config.ts — enable TinyCC on Android
# =============================================================================
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

# =============================================================================
# PATCH 2: scripts/build/deps/tinycc.ts — Android defines + patch wiring
# =============================================================================
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

# Sanity: the two TinyCC patch files must ship with the repo.
for tpf in patches/tinycc/tccrun.c.patch patches/tinycc/arm64-link.c.patch; do
    if [ ! -f "$REPO_DIR/$tpf" ]; then
        echo "  [FAIL] missing required file in bun-termux repo: $tpf"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
done

# =============================================================================
# PATCH 3: scripts/build/tools.ts — accept NDK clang (LLVM 18)
# =============================================================================
# CI runners get LLVM from apt (llvm.org script pins whatever we ask for),
# but the C++ side must compile with the NDK's clang for Bionic. NDK r27c
# ships clang 18.0.2; upstream hard-requires 21.x. Relax the discovery
# constants so the NDK toolchain satisfies the check.
TOOLS_TS="scripts/build/tools.ts"
if [ -f "$TOOLS_TS" ] && ! grep -q "$PATCH_MARKER" "$TOOLS_TS"; then
    echo "[PATCH 3] $TOOLS_TS — accept NDK clang 18"
    py_patch <<'PYEOF'
import pathlib

p = pathlib.Path("scripts/build/tools.ts")
c = p.read_text()

subs = [
    ('export const LLVM_VERSION = "21.1.8";',
     'export const LLVM_VERSION = "18.0.2"; // ANDROID_TERMUX_FIX: NDK r27c'),
    ('const LLVM_MAJOR = "21";',
     'const LLVM_MAJOR = "18"; // ANDROID_TERMUX_FIX'),
    ('const LLVM_MINOR = "1";',
     'const LLVM_MINOR = "0"; // ANDROID_TERMUX_FIX'),
]
for old, new in subs:
    assert c.count(old) == 1, f"tools.ts anchor not found (or ambiguous): {old}"
    c = c.replace(old, new, 1)

p.write_text(c)
print("  relaxed LLVM version to 18.0.x (NDK)")
PYEOF
    verify_patch "$TOOLS_TS"
elif [ -f "$TOOLS_TS" ]; then
    echo "[SKIP 3] $TOOLS_TS already patched"
fi

# =============================================================================
# PATCH 4: src/sys/lib.rs — lchmod without fchmodat2
# =============================================================================
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

# =============================================================================
# PATCH 5: src/sys/linux_syscall.rs — openat2 fallback
# =============================================================================
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

# =============================================================================
# PATCH 6: src/spawn_sys/posix_spawn.rs — shebang interpreter remap
# =============================================================================
# Android has no /usr/bin and no /bin. Scripts installed by npm packages
# (`node_modules/.bin/*`) carry shebangs like `#!/usr/bin/env node` and die
# with ENOENT at execve. This replaces the old LD_PRELOAD (termux-exec)
# shim at the source level: when the spawned path is a script whose shebang
# names a MISSING absolute interpreter, remap /usr/bin:/bin:/usr/sbin:/sbin
# entries to $PREFIX/bin and rebuild argv accordingly. Existing interpreters
# are left untouched (kernel handles valid shebangs natively).
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

helper = """    /// ANDROID_TERMUX_FIX_SHEBANG: if `script` names an existing file whose
    /// first line is a shebang pointing at an absolute interpreter that does
    /// NOT exist on this system, return the Termux equivalent for the usual
    /// FHS prefixes (/usr/bin, /bin, /usr/sbin, /sbin -> $PREFIX/bin).
    /// Returns None whenever the kernel could succeed on its own.
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

        // ANDROID_TERMUX_FIX_SHEBANG: when the target is a script whose
        // interpreter is missing, exec the Termux interpreter instead and
        // rebuild argv as [interp, script, rest...], mirroring what the
        // kernel's binfmt_script would have done.
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

# =============================================================================
# PATCH 7: src/runtime/ffi/ffi_body.rs — TinyCC search paths for Android
# =============================================================================
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

# Files that legitimately have no marker because nothing matched in 1.4
MISSING_OK=""

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
    src/runtime/ffi/ffi_body.rs; do
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

if [ -f "scripts/jsc/bindings/c-bindings.cpp" ] || [ -f "src/jsc/bindings/c-bindings.cpp" ]; then
    echo "  [INFO] c-bindings.cpp close_range: upstream already raw-syscalls on Linux; no patch needed."
fi

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
