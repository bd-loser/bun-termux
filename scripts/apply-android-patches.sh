#!/usr/bin/env bash
# apply-android-patches.sh — patches Bun source to fix Android SELinux issues
#
# What this patches:
#   1. src/resolver/resolver.rs: open_dir_absolute_z() and open_dir_z()
#      — When openat() returns EACCES (Android SELinux blocks it on / and /data/),
#        retry without O_DIRECTORY. The fd won't support readdir (ENOTDIR),
#        so the resolver treats the directory as empty — which is correct
#        since / and /data/ don't contain package.json anyway.
#
#   2. src/runtime/cli/run_command.rs: CouldntReadCurrentDirectory error path
#      — When read_dir_info returns Ok(None) on Android, don't fail fatally.
#        Instead, fall back to using the cwd as top_level_dir.
#
# These patches make Bun work natively on Termux without proot or root.

set -euo pipefail

BUN_SRC="${1:-.}"
PATCH_MARKER="# ANDROID_SELINUX_FIX_PATCH"

cd "$BUN_SRC"

echo "=== Applying Android SELinux patches to Bun source ==="

# ─── Patch 1: src/resolver/resolver.rs ─────────────────────────────────────
RESOLVER="src/resolver/resolver.rs"
if [ ! -f "$RESOLVER" ]; then
    echo "ERROR: $RESOLVER not found"
    exit 1
fi

if grep -q "$PATCH_MARKER" "$RESOLVER" 2>/dev/null; then
    echo "  [skip] $RESOLVER already patched"
else
    echo "  [patch] $RESOLVER: open_dir_absolute_z + open_dir_z EACCES fallback"

    # Patch open_dir_absolute_z: add EACCES → retry without O_DIRECTORY
    # Original: ::bun_sys::open(path, O::DIRECTORY | O::CLOEXEC | O::RDONLY | nofollow, 0).map_err(Into::into)
    # We wrap it in a match and add a fallback.
    python3 <<'PYEOF'
import re

with open("src/resolver/resolver.rs", "r") as f:
    content = f.read()

# Patch open_dir_absolute_z
old = """    ::bun_sys::open(path, O::DIRECTORY | O::CLOEXEC | O::RDONLY | nofollow, 0)
        .map_err(Into::into)
}
/// Opens a directory relative to `dir`:"""

new = """    // ANDROID_SELINUX_FIX_PATCH
    // On Android, SELinux blocks openat(O_DIRECTORY) on / and /data/ for
    // untrusted_app contexts. When EACCES is returned, retry without O_DIRECTORY.
    // The resulting fd won't support readdir (ENOTDIR), so the resolver treats
    // the directory as empty — correct for / and /data/ which don't contain
    // package.json or node_modules.
    let flags = O::DIRECTORY | O::CLOEXEC | O::RDONLY | nofollow;
    match ::bun_sys::open(path, flags, 0) {
        Ok(fd) => Ok(fd),
        Err(err) => {
            #[cfg(target_os = "android")]
            {
                if err == bun_sys::Error::EACCES {
                    let fallback_flags = O::CLOEXEC | O::RDONLY;
                    if let Ok(fd) = ::bun_sys::open(path, fallback_flags, 0) {
                        return Ok(fd);
                    }
                }
            }
            Err(err.into())
        }
    }
}
/// Opens a directory relative to `dir`:"""

if old in content:
    content = content.replace(old, new, 1)
    print("  [ok] patched open_dir_absolute_z")
else:
    print("  [warn] could not find open_dir_absolute_z pattern — may have changed")

# Patch open_dir_z: same EACCES fallback for relative path version
old2 = """        ::bun_sys::open_dir_at(dir, path).map_err(Into::into)
    }"""

new2 = """        // ANDROID_SELINUX_FIX_PATCH
        // Same EACCES fallback as open_dir_absolute_z — retry without O_DIRECTORY
        match ::bun_sys::open_dir_at(dir, path) {
            Ok(fd) => Ok(fd),
            Err(err) => {
                #[cfg(target_os = "android")]
                {
                    if err == bun_sys::Error::EACCES {
                        // Fall back: open without O_DIRECTORY using openat directly
                        let c_path = std::ffi::CString::new(path).unwrap_or_default();
                        let fd = unsafe {
                            libc::openat(
                                dir,
                                c_path.as_ptr(),
                                libc::O_CLOEXEC | libc::O_RDONLY,
                            )
                        };
                        if fd >= 0 {
                            return Ok(unsafe { Fd::from_raw(fd) });
                        }
                    }
                }
                Err(err.into())
            }
        }
    }"""

if old2 in content:
    content = content.replace(old2, new2, 1)
    print("  [ok] patched open_dir_z")
else:
    print("  [warn] could not find open_dir_z pattern — may have changed")

with open("src/resolver/resolver.rs", "w") as f:
    f.write(content)
PYEOF
fi

# ─── Patch 2: src/runtime/cli/run_command.rs ──────────────────────────────
RUN_CMD="src/runtime/cli/run_command.rs"
if [ ! -f "$RUN_CMD" ]; then
    echo "ERROR: $RUN_CMD not found"
    exit 1
fi

if grep -q "$PATCH_MARKER" "$RUN_CMD" 2>/dev/null; then
    echo "  [skip] $RUN_CMD already patched"
else
    echo "  [patch] $RUN_CMD: CouldntReadCurrentDirectory fallback to cwd"

    python3 <<'PYEOF'
with open("src/runtime/cli/run_command.rs", "r") as f:
    content = f.read()

# Patch the Ok(None) arm — instead of fatal error, continue with cwd
old = """                Ok(None) => {
                    // SAFETY: see `Err` arm above.
                    let _ = unsafe { ctx.log() }.print(std::ptr::from_mut::<bun_core::io::Writer>(
                        Output::error_writer(),
                    ));
                    pretty_errorln!("error loading current directory");
                    Output::flush();
                    return Err(bun_core::err!("CouldntReadCurrentDirectory"));
                }"""

new = """                Ok(None) => {
                    // ANDROID_SELINUX_FIX_PATCH
                    // On Android, the directory walk may fail to open ancestors
                    // (/ and /data/) due to SELinux. Instead of failing fatally,
                    // continue with the cwd as top_level_dir. This allows Bun
                    // to run even when the full directory walk is blocked.
                    #[cfg(target_os = "android")]
                    {
                        // Re-read dir_info for the cwd itself (not the walked root)
                        match this_transpiler.resolver.read_dir_info(b".") {
                            Ok(Some(info)) => {
                                eprintln!("[bun-android-fix] using cwd as top_level_dir (directory walk blocked by SELinux)");
                                info
                            }
                            _ => {
                                let _ = unsafe { ctx.log() }.print(std::ptr::from_mut::<bun_core::io::Writer>(
                                    Output::error_writer(),
                                ));
                                pretty_errorln!("error loading current directory");
                                Output::flush();
                                return Err(bun_core::err!("CouldntReadCurrentDirectory"));
                            }
                        }
                    }
                    #[cfg(not(target_os = "android"))]
                    {
                        let _ = unsafe { ctx.log() }.print(std::ptr::from_mut::<bun_core::io::Writer>(
                            Output::error_writer(),
                        ));
                        pretty_errorln!("error loading current directory");
                        Output::flush();
                        return Err(bun_core::err!("CouldntReadCurrentDirectory"));
                    }
                }"""

if old in content:
    content = content.replace(old, new, 1)
    print("  [ok] patched CouldntReadCurrentDirectory fallback")
else:
    print("  [warn] could not find Ok(None) pattern — may have changed")

with open("src/runtime/cli/run_command.rs", "w") as f:
    f.write(content)
PYEOF
fi

echo ""
echo "=== Patches applied successfully ==="
echo "Verify with: grep -n 'ANDROID_SELINUX_FIX_PATCH' src/resolver/resolver.rs src/runtime/cli/run_command.rs"
