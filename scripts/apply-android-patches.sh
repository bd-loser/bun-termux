#!/usr/bin/env bash
# apply-android-patches.sh — patches Bun source to fix Android SELinux issues
#
# For Bun v1.3.14 (Zig codebase)
#
# What this patches:
#   1. src/bun.zig: openDirForIteration() and openDirAbsolute()
#      — When openat() returns EACCES, retry without O_DIRECTORY.
#        Safe on all platforms (only triggers on EACCES).
#
#   2. src/cli/run_command.zig: CouldntReadCurrentDirectory error path
#      — When readDirInfo returns null, retry with "." (cwd).
#        Safe on all platforms (only triggers when walk fails).

set -euo pipefail

BUN_SRC="${1:-.}"
PATCH_MARKER="// ANDROID_SELINUX_FIX_PATCH"

cd "$BUN_SRC"

echo "=== Applying Android SELinux patches to Bun source (v1.3.14 Zig codebase) ==="

# ─── Patch 1: src/bun.zig — openDirForIteration + openDirAbsolute ─────────
BUN_ZIG="src/bun.zig"
if [ ! -f "$BUN_ZIG" ]; then
    echo "ERROR: $BUN_ZIG not found"
    exit 1
fi

if grep -q "$PATCH_MARKER" "$BUN_ZIG" 2>/dev/null; then
    echo "  [skip] $BUN_ZIG already patched"
else
    echo "  [patch] $BUN_ZIG: openDirForIteration + openDirAbsolute EACCES fallback"

    python3 <<'PYEOF'
with open("src/bun.zig", "r") as f:
    content = f.read()

# Patch openDirForIteration: wrap the openatA call to handle EACCES
# Note: Zig's os.linux.E enum uses .ACCES (not .EACCES)
old1 = """pub fn openDirForIteration(dir: FD, path_: []const u8) sys.Maybe(FD) {
    if (comptime Environment.isWindows) {
        return sys.openDirAtWindowsA(dir, path_, .{ .iterable = true, .can_rename_or_delete = false, .read_only = true });
    }
    return sys.openatA(dir, path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0);
}"""

new1 = """pub fn openDirForIteration(dir: FD, path_: []const u8) sys.Maybe(FD) {
    // ANDROID_SELINUX_FIX_PATCH
    // On Android, SELinux blocks openat(O_DIRECTORY) on / and /data/ for
    // untrusted_app contexts. When EACCES is returned, retry without O_DIRECTORY.
    // The resulting fd won't support readdir (ENOTDIR), so the resolver treats
    // the directory as empty — correct for / and /data/ which don't contain
    // package.json or node_modules. Safe on all platforms (only triggers on EACCES).
    if (comptime Environment.isWindows) {
        return sys.openDirAtWindowsA(dir, path_, .{ .iterable = true, .can_rename_or_delete = false, .read_only = true });
    }
    const result = sys.openatA(dir, path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0);
    if (result == .err and result.err.getErrno() == .ACCES) {
        // Retry without O_DIRECTORY — returns a regular fd that works with fstat
        return sys.openatA(dir, path_, O.CLOEXEC | O.RDONLY, 0);
    }
    return result;
}"""

if old1 in content:
    content = content.replace(old1, new1, 1)
    print("  [ok] patched openDirForIteration")
else:
    print("  [warn] could not find openDirForIteration pattern")

# Patch openDirAbsolute: same EACCES fallback
old2 = """pub fn openDirAbsolute(path_: []const u8) !std.fs.Dir {
    const fd = if (comptime Environment.isWindows)
        try sys.openDirAtWindowsA(invalid_fd, path_, .{ .iterable = true, .can_rename_or_delete = true, .read_only = true }).unwrap()
    else
        try sys.openA(path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0).unwrap();

    return fd.stdDir();
}"""

new2 = """pub fn openDirAbsolute(path_: []const u8) !std.fs.Dir {
    // ANDROID_SELINUX_FIX_PATCH
    // Same EACCES fallback as openDirForIteration — retry without O_DIRECTORY
    const fd = if (comptime Environment.isWindows)
        try sys.openDirAtWindowsA(invalid_fd, path_, .{ .iterable = true, .can_rename_or_delete = true, .read_only = true }).unwrap()
    else blk: {
        const result = sys.openA(path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0);
        if (result == .err and result.err.getErrno() == .ACCES) {
            break :blk try sys.openA(path_, O.CLOEXEC | O.RDONLY, 0).unwrap();
        }
        break :blk try result.unwrap();
    };

    return fd.stdDir();
}"""

if old2 in content:
    content = content.replace(old2, new2, 1)
    print("  [ok] patched openDirAbsolute")
else:
    print("  [warn] could not find openDirAbsolute pattern")

# Also patch openDirAbsoluteNotForDeletingOrRenaming
old3 = """pub fn openDirAbsoluteNotForDeletingOrRenaming(path_: []const u8) !std.fs.Dir {
    const fd = if (comptime Environment.isWindows)
        try sys.openDirAtWindowsA(invalid_fd, path_, .{ .iterable = true, .can_rename_or_delete = false, .read_only = true }).unwrap()
    else
        try sys.openA(path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0).unwrap();

    return fd.stdDir();
}"""

new3 = """pub fn openDirAbsoluteNotForDeletingOrRenaming(path_: []const u8) !std.fs.Dir {
    // ANDROID_SELINUX_FIX_PATCH
    const fd = if (comptime Environment.isWindows)
        try sys.openDirAtWindowsA(invalid_fd, path_, .{ .iterable = true, .can_rename_or_delete = false, .read_only = true }).unwrap()
    else blk: {
        const result = sys.openA(path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0);
        if (result == .err and result.err.getErrno() == .ACCES) {
            break :blk try sys.openA(path_, O.CLOEXEC | O.RDONLY, 0).unwrap();
        }
        break :blk try result.unwrap();
    };

    return fd.stdDir();
}"""

if old3 in content:
    content = content.replace(old3, new3, 1)
    print("  [ok] patched openDirAbsoluteNotForDeletingOrRenaming")
else:
    print("  [warn] could not find openDirAbsoluteNotForDeletingOrRenaming pattern")

with open("src/bun.zig", "w") as f:
    f.write(content)
PYEOF
fi

# ─── Patch 2: src/cli/run_command.zig — CouldntReadCurrentDirectory ──────
RUN_CMD="src/cli/run_command.zig"
if [ ! -f "$RUN_CMD" ]; then
    echo "ERROR: $RUN_CMD not found"
    exit 1
fi

if grep -q "$PATCH_MARKER" "$RUN_CMD" 2>/dev/null; then
    echo "  [skip] $RUN_CMD already patched"
else
    echo "  [patch] $RUN_CMD: CouldntReadCurrentDirectory fallback to cwd"

    python3 <<'PYEOF'
with open("src/cli/run_command.zig", "r") as f:
    content = f.read()

# The actual v1.3.14 code uses orelse:
old = """        const root_dir_info = this_transpiler.resolver.readDirInfo(this_transpiler.fs.top_level_dir) catch |err| {
            if (!log_errors) return error.CouldntReadCurrentDirectory;
            ctx.log.print(Output.errorWriter()) catch {};
            Output.prettyErrorln("<r><red>error<r><d>:<r> <b>{s}<r> loading directory {f}", .{ @errorName(err), bun.fmt.QuotedFormatter{ .text = this_transpiler.fs.top_level_dir } });
            Output.flush();
            return err;
        } orelse {
            ctx.log.print(Output.errorWriter()) catch {};
            Output.prettyErrorln("error loading current directory", .{});
            Output.flush();
            return error.CouldntReadCurrentDirectory;
        };"""

new = """        // ANDROID_SELINUX_FIX_PATCH
        // On Android, the directory walk may fail to open ancestors
        // (/ and /data/) due to SELinux. When readDirInfo returns null
        // (directory walk found nothing), fall back to using cwd directly.
        // Safe on all platforms — only triggers when the walk returns null.
        const root_dir_info = this_transpiler.resolver.readDirInfo(this_transpiler.fs.top_level_dir) catch |err| {
            if (!log_errors) return error.CouldntReadCurrentDirectory;
            ctx.log.print(Output.errorWriter()) catch {};
            Output.prettyErrorln("<r><red>error<r><d>:<r> <b>{s}<r> loading directory {f}", .{ @errorName(err), bun.fmt.QuotedFormatter{ .text = this_transpiler.fs.top_level_dir } });
            Output.flush();
            return err;
        } orelse blk: {
            // Retry with "." (current directory) — bypasses the directory walk.
            // readDirInfo returns !?*DirInfo; catch null converts errors to null.
            if (this_transpiler.resolver.readDirInfo(".") catch null) |cwd_info| {
                break :blk cwd_info;
            }
            ctx.log.print(Output.errorWriter()) catch {};
            Output.prettyErrorln("error loading current directory", .{});
            Output.flush();
            return error.CouldntReadCurrentDirectory;
        };"""

if old in content:
    content = content.replace(old, new, 1)
    print("  [ok] patched readDirInfo orelse with cwd fallback")
else:
    print("  [warn] could not find readDirInfo pattern — may have changed")

with open("src/cli/run_command.zig", "w") as f:
    f.write(content)
PYEOF
fi

echo ""
echo "=== Patches applied successfully ==="
echo "Verify with: grep -n 'ANDROID_SELINUX_FIX_PATCH' src/bun.zig src/cli/run_command.zig"

# ─── Patch 3: scripts/build/flags.ts — fix cross-compile CPU flags ────────
FLAGS_TS="scripts/build/flags.ts"
if [ ! -f "$FLAGS_TS" ]; then
    echo "  [warn] $FLAGS_TS not found (skipping CPU flag patch)"
else
    if grep -q "ANDROID_SELINUX_FIX_PATCH" "$FLAGS_TS" 2>/dev/null; then
        echo "  [skip] $FLAGS_TS already patched"
    else
        echo "  [patch] $FLAGS_TS: fix cross-compile CPU flags"
        sed -i 's/"-march=armv8-a+crc"/"-march=armv8-a"/g' "$FLAGS_TS"
        sed -i '1i // ANDROID_SELINUX_FIX_PATCH: simplified march flags for cross-compile' "$FLAGS_TS"
        echo "  [ok] patched flags.ts — removed +crc feature flag"
    fi
fi

# ─── Patch 4: scripts/build/tools.ts — allow NDK clang 18 (ABI fix) ──────
TOOLS_TS="scripts/build/tools.ts"
if [ ! -f "$TOOLS_TS" ]; then
    echo "  [warn] $TOOLS_TS not found (skipping clang version patch)"
else
    if grep -q "ANDROID_SELINUX_FIX_PATCH" "$TOOLS_TS" 2>/dev/null; then
        echo "  [skip] $TOOLS_TS already patched"
    else
        echo "  [patch] $TOOLS_TS: lower clang version requirement to 18 (NDK r27c)"
        sed -i 's/export const LLVM_VERSION = "21.1.8";/export const LLVM_VERSION = "18.0.3"; \/\/ ANDROID_SELINUX_FIX_PATCH: NDK r27c clang/' "$TOOLS_TS"
        sed -i 's/const LLVM_MAJOR = "21";/const LLVM_MAJOR = "18"; \/\/ ANDROID_SELINUX_FIX_PATCH/' "$TOOLS_TS"
        sed -i 's/const LLVM_MINOR = "1";/const LLVM_MINOR = "0"; \/\/ ANDROID_SELINUX_FIX_PATCH/' "$TOOLS_TS"
        sed -i 's|paths.push(`/usr/lib/llvm-${LLVM_MAJOR}.${LLVM_MINOR}.0/bin`);|paths.push(`/usr/lib/llvm-${LLVM_MAJOR}.${LLVM_MINOR}.0/bin`);\n    // ANDROID_SELINUX_FIX_PATCH: NDK clang\n    paths.push(`${process.env.ANDROID_NDK_HOME \|\| process.env.ANDROID_NDK_ROOT \|\| "/opt/android-ndk"}/toolchains/llvm/prebuilt/linux-x86_64/bin`);|' "$TOOLS_TS"
        echo "  [ok] patched tools.ts — clang 18 + NDK search path"
    fi
fi

# ─── Patch 5: scripts/build/flags.ts — remove clang 19+ warning flags ────
# (already patched by Patch 3, but also need to remove -Wno-character-conversion
# which NDK clang 18 doesn't recognize)
if [ -f "scripts/build/flags.ts" ]; then
    if grep -q "Wno-character-conversion" "scripts/build/flags.ts" 2>/dev/null; then
        echo "  [patch] scripts/build/flags.ts: remove -Wno-character-conversion (clang 19+ only)"
        sed -i '/"-Wno-character-conversion",/d' "scripts/build/flags.ts"
        echo "  [ok] removed -Wno-character-conversion"
    fi
fi
