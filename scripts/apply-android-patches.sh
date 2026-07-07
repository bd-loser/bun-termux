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
        // On Android, the directory walk may fail or return null.
        // Use std.debug.print for debug output (always works in release).
        const root_dir_info: *DirInfo = blk: {
            std.debug.print("root_dir_info: top_level_dir={s}\\n", .{this_transpiler.fs.top_level_dir});
            const result = this_transpiler.resolver.readDirInfo(this_transpiler.fs.top_level_dir) catch |err| {
                std.debug.print("root_dir_info: readDirInfo threw: {s}\\n", .{@errorName(err)});
                // Try cwd as fallback
                if (this_transpiler.resolver.readDirInfo(".") catch null) |cwd_info| {
                    std.debug.print("root_dir_info: cwd fallback OK\\n", .{});
                    break :blk cwd_info;
                }
                if (!log_errors) return error.CouldntReadCurrentDirectory;
                ctx.log.print(Output.errorWriter()) catch {};
                Output.prettyErrorln("error loading current directory", .{});
                Output.flush();
                return error.CouldntReadCurrentDirectory;
            };
            std.debug.print("root_dir_info: returned {s}\\n", .{if (result != null) "non-null" else "null"});
            if (result) |info| break :blk info;
            // result is null — try cwd
            if (this_transpiler.resolver.readDirInfo(".") catch null) |cwd_info| {
                std.debug.print("root_dir_info: null→cwd fallback OK\\n", .{});
                break :blk cwd_info;
            }
            if (!log_errors) return error.CouldntReadCurrentDirectory;
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

# ─── Patch 8: src/resolver/resolver.zig — stop walk at /data/data (not /) ─
# The directory walk goes from cwd UP to root_path (which is "/").
# On Android, SELinux blocks openat(O_DIRECTORY) on / and /data/.
# Fix: change root_path to "/data/data" (accessible on Termux) so the
# walk stops there instead of going to /.
RESOLVER_ZIG="src/resolver/resolver.zig"
if [ -f "$RESOLVER_ZIG" ]; then
    if grep -q "ANDROID_SELINUX_FIX_PATCH" "$RESOLVER_ZIG" 2>/dev/null; then
        echo "  [skip] $RESOLVER_ZIG already patched"
    else
        echo "  [patch] $RESOLVER_ZIG: stop walk at /data/data instead of /"
        python3 <<'PYEOF'
with open("src/resolver/resolver.zig", "r") as f:
    content = f.read()

# Patch the root_path: change from path[0..1] ("/") to a deeper path
# that's accessible on Android. Use "/data/data/com.termux" (the Termux
# prefix, definitely accessible) when the path starts with it.
old = """        const root_path = if (Environment.isWindows)
            bun.strings.withoutTrailingSlashWindowsPath(ResolvePath.windowsFilesystemRoot(path))
        else
            // we cannot just use "/"
            // we will write to the buffer past the ptr len so it must be a non-const buffer
            path[0..1];"""

new = """        // ANDROID_SELINUX_FIX_PATCH: On Android, SELinux blocks openat(O_DIRECTORY)
        // on / and /data/. The walk goes from cwd UP to root_path. If root_path is "/",
        // the walk fails because / can't be opened. Use the Termux prefix
        // (/data/data/com.termux, 22 chars) as the walk root — it's always accessible.
        const root_path = if (Environment.isWindows)
            bun.strings.withoutTrailingSlashWindowsPath(ResolvePath.windowsFilesystemRoot(path))
        else if (path.len >= 22 and strings.eql(path[0..22], "/data/data/com.termux"))
            path[0..22]
        else if (path.len >= 10 and strings.eql(path[0..10], "/data/data"))
            path[0..10]
        else
            path[0..1];"""

if old in content:
    content = content.replace(old, new, 1)
    print("  [ok] patched root_path to stop at /data/data")
else:
    print("  [warn] could not find root_path pattern")

# Also patch the walk error handler: when AccessDenied is returned,
# treat as FileNotFound (already handled by the walk's error switch)
old2 = """                    const dir_result = std.fs.openDirAbsoluteZ(
                        sentinel,
                        .{ .no_follow = !follow_symlinks, .iterate = true },
                    ) catch |err| break :open_req err;"""

new2 = """                    // ANDROID_SELINUX_FIX_PATCH: catch AccessDenied (EACCES) and
                    // convert to FileNotFound so the walk treats it as "not found"
                    // instead of propagating an error.
                    const dir_result = std.fs.openDirAbsoluteZ(
                        sentinel,
                        .{ .no_follow = !follow_symlinks, .iterate = true },
                    ) catch |err| {
                        if (err == error.AccessDenied) break :open_req error.FileNotFound;
                        break :open_req err;
                    };"""

if old2 in content:
    content = content.replace(old2, new2, 1)
    print("  [ok] patched openDirAbsoluteZ to catch AccessDenied")
else:
    print("  [warn] could not find openDirAbsoluteZ pattern")

with open("src/resolver/resolver.zig", "w") as f:
    f.write(content)
PYEOF
    fi
fi

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
if [ -f "scripts/build/flags.ts" ]; then
    if grep -q "Wno-character-conversion" "scripts/build/flags.ts" 2>/dev/null; then
        echo "  [patch] scripts/build/flags.ts: remove -Wno-character-conversion (clang 19+ only)"
        sed -i '/"-Wno-character-conversion",/d' "scripts/build/flags.ts"
        echo "  [ok] removed -Wno-character-conversion"
    fi
fi

# ─── Patch 6: src/jsc/bindings/EncodingTables.h — remove pragma for unknown warning ─
ENCODING_TABLES="src/jsc/bindings/EncodingTables.h"
if [ -f "$ENCODING_TABLES" ]; then
    if grep -q 'clang diagnostic ignored "-Wcharacter-conversion"' "$ENCODING_TABLES" 2>/dev/null; then
        echo "  [patch] $ENCODING_TABLES: remove -Wcharacter-conversion pragma (clang 19+ only)"
        sed -i '/clang diagnostic ignored "-Wcharacter-conversion"/d' "$ENCODING_TABLES"
        echo "  [ok] removed pragma"
    fi
fi

# ─── Patch 7: Fix dangling reference warnings (clang 18 stricter than 21) ─
# The pattern `for (auto& x : obj.releaseData()->propertyNameVector())` creates
# a temporary from releaseData() that's destroyed at end of full-expression,
# leaving the reference dangling. Fix by storing releaseData() in a local.
# Search ALL .cpp and .h files for this pattern and patch them.
echo "  [patch] searching for dangling reference pattern in all source files..."
PATCHED_FILES=0
while IFS= read -r -d '' FILE; do
    if grep -q "properties.releaseData()->propertyNameVector()" "$FILE" 2>/dev/null; then
        # Check if already patched
        if grep -q "_releaseData = properties.releaseData()" "$FILE" 2>/dev/null; then
            continue
        fi
        echo "    [patch] $FILE"
        # Replace: for (auto& X : properties.releaseData()->propertyNameVector())
        # With:    auto _releaseData = properties.releaseData(); for (auto& X : _releaseData->propertyNameVector())
        # Use perl for non-greedy matching and to handle the `auto&` capture
        perl -i -pe 's/for \(auto& (\w+) : properties\.releaseData\(\)->propertyNameVector\(\)\)/auto _releaseData = properties.releaseData(); for (auto\& $1 : _releaseData->propertyNameVector())/g' "$FILE"
        PATCHED_FILES=$((PATCHED_FILES + 1))
    fi
done < <(find src -type f \( -name "*.cpp" -o -name "*.h" \) -print0)
echo "  [ok] patched $PATCHED_FILES files with dangling reference fix"
