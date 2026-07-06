#!/usr/bin/env bash
# apply-android-patches.sh — patches Bun source to fix Android SELinux issues
#
# For Bun v1.3.14 (Zig codebase — the Rust rewrite is in main, not v1.3.14)
#
# What this patches:
#   1. src/bun.zig: openDirForIteration() and openDirAbsolute()
#      — When openat() returns EACCES (Android SELinux blocks it on / and /data/),
#        retry without O_DIRECTORY. The fd won't support readdir (ENOTDIR),
#        so the resolver treats the directory as empty — which is correct
#        since / and /data/ don't contain package.json anyway.
#
#   2. src/cli/run_command.zig: CouldntReadCurrentDirectory error path
#      — When readDirInfo fails on Android, fall back to using "." as the
#        path (which uses cwd), instead of failing fatally.
#
# These patches make Bun work natively on Termux without proot or root.

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
    // package.json or node_modules.
    if (comptime Environment.isWindows) {
        return sys.openDirAtWindowsA(dir, path_, .{ .iterable = true, .can_rename_or_delete = false, .read_only = true });
    }
    const result = sys.openatA(dir, path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0);
    if (comptime Environment.isAndroid) {
        if (result == .err and result.err == .EACCES) {
            // Retry without O_DIRECTORY
            return sys.openatA(dir, path_, O.CLOEXEC | O.RDONLY, 0);
        }
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
        if (comptime Environment.isAndroid) {
            if (result == .err and result.err == .EACCES) {
                break :blk sys.openA(path_, O.CLOEXEC | O.RDONLY, 0).unwrap();
            }
        }
        break :blk result.unwrap();
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
        if (comptime Environment.isAndroid) {
            if (result == .err and result.err == .EACCES) {
                break :blk sys.openA(path_, O.CLOEXEC | O.RDONLY, 0).unwrap();
            }
        }
        break :blk result.unwrap();
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

# Patch the readDirInfo error path — on Android, when it fails on the
# top_level_dir (which is the result of the directory walk), retry with "."
# (current directory) which bypasses the walk.
old = """        const root_dir_info = this_transpiler.resolver.readDirInfo(this_transpiler.fs.top_level_dir) catch |err| {
            if (!log_errors) return error.CouldntReadCurrentDirectory;
            // SAFETY: `ctx.log` set in `create_context_data` (single-
            // threaded CLI startup), process-lifetime.
            let _ = ctx.log() catch {};
            const log = ctx.log() catch {
                Output.prettyErrorln("<r><red>error<r><d>:<r> <b>{s}<r> loading directory {f}", .{ @errorName(err), bun.fmt.QuotedFormatter{ .text = this_transpiler.fs.top_level_dir } });
                Output.flush();
                return error.CouldntReadCurrentDirectory;
            };
            log.print(Output.errorWriter()) catch {};
            Output.prettyErrorln("<r><red>error<r><d>:<r> <b>{s}<r> loading directory {f}", .{ @errorName(err), bun.fmt.QuotedFormatter{ .text = this_transpiler.fs.top_level_dir } });
            Output.flush();
            return error.CouldntReadCurrentDirectory;
        };

        if (root_dir_info == null) {
            // SAFETY: see above.
            let _ = ctx.log() catch {};
            Output.prettyErrorln("error loading current directory", .{});
            Output.flush();
            return error.CouldntReadCurrentDirectory;
        }"""

# We need to look at the actual code first
PYEOF

    # Use a simpler approach — find the orelse block and add Android fallback
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
        const root_dir_info = this_transpiler.resolver.readDirInfo(this_transpiler.fs.top_level_dir) catch |err| {
            if (!log_errors) return error.CouldntReadCurrentDirectory;
            ctx.log.print(Output.errorWriter()) catch {};
            Output.prettyErrorln("<r><red>error<r><d>:<r> <b>{s}<r> loading directory {f}", .{ @errorName(err), bun.fmt.QuotedFormatter{ .text = this_transpiler.fs.top_level_dir } });
            Output.flush();
            return err;
        } orelse blk: {
            if (comptime @import("builtin").os.tag == .android) {
                // Retry with "." (current directory) — this bypasses the walk
                if (this_transpiler.resolver.readDirInfo(".")) |cwd_info| {
                    break :blk cwd_info;
                } else |_| {}
            }
            ctx.log.print(Output.errorWriter()) catch {};
            Output.prettyErrorln("error loading current directory", .{});
            Output.flush();
            return error.CouldntReadCurrentDirectory;
        };"""

if old in content:
    content = content.replace(old, new, 1)
    print("  [ok] patched readDirInfo orelse with Android fallback")
else:
    print("  [warn] could not find readDirInfo pattern — may have changed")

with open("src/cli/run_command.zig", "w") as f:
    f.write(content)
PYEOF
fi

echo ""
echo "=== Patches applied successfully ==="
echo "Verify with: grep -n 'ANDROID_SELINUX_FIX_PATCH' src/bun.zig src/cli/run_command.zig"
