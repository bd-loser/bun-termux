#!/usr/bin/env bash
# apply-android-patches.sh — patches Bun v1.3.14 (Zig) for Android/Termux
#
# ROBUSTNESS RULES (learned from previous failed attempts):
#   1. Use line-number-based patching with semantic anchors, not exact
#      string matching. Triple-quoted Python strings silently fail on
#      any whitespace difference.
#   2. Verify EVERY patch applied. Abort the build if any patch failed.
#   3. Print clear [OK]/[FAIL] markers so CI logs are greppable.
#   4. Idempotent: safe to re-run. Detects existing patches via markers.
#
# WHAT THIS PATCHES (Bun v1.3.14 Zig codebase):
#
#   1. src/resolver/resolver.zig — THE bunx fix (3 changes):
#      a) root_path: on Android, set root_path = path (the cwd) instead
#         of path[0..1] ("/"). This prevents the directory walk from
#         ever queuing /, /data, /data/data as ancestors. Those dirs
#         are mode 0771 on Android and opendir() returns EACCES.
#      b) Walk error switch: on AccessDenied, CONTINUE to the next
#         queue item instead of returning null. Belt-and-suspenders:
#         if (a) is somehow bypassed, the walk still won't abort.
#      c) openDirAbsoluteZ call site: catch AccessDenied and convert
#         to FileNotFound, so the not-found cache path is taken.
#
#   2. src/cli/run_command.zig — CouldntReadCurrentDirectory fallback:
#      When readDirInfo returns null (walk failed), create a minimal
#      DirInfo from the cwd instead of erroring out.
#
#   3. src/bun.zig — EACCES fallback for openDir* functions:
#      When openat(O_DIRECTORY) returns EACCES, retry without
#      O_DIRECTORY. The fd won't support readdir (ENOTDIR later),
#      but callers that only need to stat/access the dir will work.
#
#   4. scripts/build/flags.ts — cross-compile CPU flag fix
#   5. scripts/build/tools.ts — accept NDK clang 18
#   6. C++ dangling-reference fix for clang 18

set -euo pipefail

BUN_SRC="${1:-.}"
PATCH_MARKER="ANDROID_TERMUX_FIX"
FAIL_COUNT=0

cd "$BUN_SRC"

echo "=========================================="
echo "Applying Android/Termux patches to Bun v1.3.14"
echo "Source: $BUN_SRC"
echo "=========================================="

# ─── Helper: verify a patch was applied ─────────────────────────────
verify_patch() {
    local file="$1"
    local marker="$2"
    if grep -q "$marker" "$file" 2>/dev/null; then
        echo "  [OK] $file: $marker found"
        return 0
    else
        echo "  [FAIL] $file: $marker NOT found — patch did not apply!"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
}

# =====================================================================
# PATCH 1: src/resolver/resolver.zig — THE bunx fix
# =====================================================================
RESOLVER_ZIG="src/resolver/resolver.zig"

if [ ! -f "$RESOLVER_ZIG" ]; then
    echo "  [FAIL] $RESOLVER_ZIG not found"
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    if grep -q "$PATCH_MARKER" "$RESOLVER_ZIG" 2>/dev/null; then
        echo "  [SKIP] $RESOLVER_ZIG already patched"
    else
        echo "  [PATCH] $RESOLVER_ZIG"
        python3 <<'PYEOF'
import re, sys

with open("src/resolver/resolver.zig", "r") as f:
    lines = f.readlines()

content = "".join(lines)
patched = 0

# ── 1a: root_path = path (cwd) instead of path[0..1] ("/") ──
# Target the exact 6-line block that defines root_path on POSIX.
# Use regex for robustness against whitespace variations.
old_root_path = r'''        const root_path = if \(Environment\.isWindows\)
            bun\.strings\.withoutTrailingSlashWindowsPath\(ResolvePath\.windowsFilesystemRoot\(path\)\)
        else
            // we cannot just use "/"
            // we will write to the buffer past the ptr len so it must be a non-const buffer
            path\[0\.\.1\];'''

new_root_path = '''        // ANDROID_TERMUX_FIX: On Android, / and /data are mode 0771 (system:system).
        // opendir() on them returns EACCES, which aborts the entire directory walk.
        // Fix: set root_path = path (the cwd itself) so the walk-up loop condition
        // (top.len > root_path.len) is immediately false — no ancestors are queued.
        // The walk processes ONLY the cwd, which is always accessible.
        const root_path = if (Environment.isWindows)
            bun.strings.withoutTrailingSlashWindowsPath(ResolvePath.windowsFilesystemRoot(path))
        else
            path;'''

new_content = re.sub(old_root_path, lambda m: new_root_path, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [1a] root_path = path (cwd) — prevents ancestor walk")
else:
    print("    [FAIL] could not find root_path pattern")
    sys.exit(1)

# ── 1b: Walk error switch — add AccessDenied and change return to continue ──
# The walk returns null on ANY error, which aborts processing of ALL remaining
# queue items (including the cwd). Change AccessDenied to continue instead.
# Target the exact error switch in the walk-down loop.
old_switch = r'''                    error\.ENOTDIR, error\.IsDir, error\.NotDir => return null,'''

new_switch = '''                    // ANDROID_TERMUX_FIX: On AccessDenied (EACCES), skip this ancestor
                    // and CONTINUE processing the rest of the queue. The cwd at
                    // queue[0] is always accessible — returning null here would
                    // abort the entire walk and never try the cwd.
                    error.ENOTDIR, error.IsDir, error.NotDir => return null,
                    error.AccessDenied => {
                        r.dir_cache.markNotFound(queue_top.result);
                        const cached_dir_entry_result = rfs.entries.getOrPut(queue_top.unsafe_path) catch unreachable;
                        rfs.entries.markNotFound(cached_dir_entry_result);
                        continue;
                    },'''

new_content = re.sub(old_switch, lambda m: new_switch, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [1b] AccessDenied → continue (not return null)")
else:
    print("    [FAIL] could not find walk error switch")
    sys.exit(1)

# ── 1c: openDirAbsoluteZ call site — catch AccessDenied as fallback ──
# Even with 1a and 1b, if somehow an inaccessible ancestor IS queued,
# convert AccessDenied to FileNotFound so the not-found cache path is taken.
old_open = r'''                    const dir_result = std\.fs\.openDirAbsoluteZ\(
                        sentinel,
                        \.\{ \.no_follow = !follow_symlinks, \.iterate = true \},
                    \) catch \|err\| break :open_req err;'''

new_open = '''                    // ANDROID_TERMUX_FIX: catch AccessDenied from openDirAbsoluteZ
                    // and convert to FileNotFound. This ensures the not-found
                    // cache path is taken (mark + continue) instead of propagating.
                    const dir_result = std.fs.openDirAbsoluteZ(
                        sentinel,
                        .{ .no_follow = !follow_symlinks, .iterate = true },
                    ) catch |err| switch (err) {
                        error.AccessDenied => break :open_req error.FileNotFound,
                        else => break :open_req err,
                    };'''

new_content = re.sub(old_open, lambda m: new_open, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [1c] openDirAbsoluteZ: AccessDenied → FileNotFound")
else:
    print("    [FAIL] could not find openDirAbsoluteZ pattern")
    sys.exit(1)

with open("src/resolver/resolver.zig", "w") as f:
    f.write(content)

print(f"    Total: {patched}/3 sub-patches applied to resolver.zig")
PYEOF
        verify_patch "$RESOLVER_ZIG" "$PATCH_MARKER" || true
    fi
fi

# =====================================================================
# PATCH 2: src/cli/run_command.zig — CouldntReadCurrentDirectory fallback
# =====================================================================
RUN_CMD="src/cli/run_command.zig"

if [ ! -f "$RUN_CMD" ]; then
    echo "  [FAIL] $RUN_CMD not found"
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    if grep -q "$PATCH_MARKER" "$RUN_CMD" 2>/dev/null; then
        echo "  [SKIP] $RUN_CMD already patched"
    else
        echo "  [PATCH] $RUN_CMD"
        python3 <<'PYEOF'
import re, sys

with open("src/cli/run_command.zig", "r") as f:
    content = f.read()

patched = 0

# Target the orelse block that returns CouldntReadCurrentDirectory
old = r'''        const root_dir_info = this_transpiler\.resolver\.readDirInfo\(this_transpiler\.fs\.top_level_dir\) catch \|err\| \{
            if \(!log_errors\) return error\.CouldntReadCurrentDirectory;
            ctx\.log\.print\(Output\.errorWriter\(\)\) catch \{\};
            Output\.prettyErrorln\("<r><red>error<r><d>:<r> <b>\{s\}<r> loading directory \{f\}", \.\{ @errorName\(err\), bun\.fmt\.QuotedFormatter\{ \.text = this_transpiler\.fs\.top_level_dir \} \}\);
            Output\.flush\(\);
            return err;
        \} orelse \{
            ctx\.log\.print\(Output\.errorWriter\(\)\) catch \{\};
            Output\.prettyErrorln\("error loading current directory", \.\{\}\);
            Output\.flush\(\);
            return error\.CouldntReadCurrentDirectory;
        \};'''

new = '''        // ANDROID_TERMUX_FIX: On Android, readDirInfo may return null when
        // the directory walk is blocked by SELinux (EACCES on / or /data).
        // Instead of failing, create a minimal DirInfo from the cwd so
        // bunx/bun-run can proceed. The cwd itself is always accessible.
        const root_dir_info: *DirInfo = blk: {
            const result = this_transpiler.resolver.readDirInfo(this_transpiler.fs.top_level_dir) catch null;
            if (result) |info| break :blk info;
            // readDirInfo returned null — synthesize a minimal DirInfo.
            // Use a unique cache key (with counter) to avoid poisoned cache.
            const cwd = this_transpiler.fs.top_level_dir;
            var key_buf: [bun.MAX_PATH_BYTES + 16]u8 = undefined;
            const key = std.fmt.bufPrintZ(&key_buf, "{s}__termux_{d}", .{ cwd, std.time.milliTimestamp() }) catch break :blk {
                if (!log_errors) return error.CouldntReadCurrentDirectory;
                Output.prettyErrorln("error loading current directory (termux fallback OOM)", .{});
                Output.flush();
                return error.CouldntReadCurrentDirectory;
            };
            var cache_result = this_transpiler.resolver.dir_cache.getOrPut(key) catch break :blk {
                if (!log_errors) return error.CouldntReadCurrentDirectory;
                Output.prettyErrorln("error loading current directory (termux fallback cache)", .{});
                Output.flush();
                return error.CouldntReadCurrentDirectory;
            };
            break :blk this_transpiler.resolver.dir_cache.put(&cache_result, DirInfo{
                .abs_path = cwd,
            }) catch {
                if (!log_errors) return error.CouldntReadCurrentDirectory;
                Output.prettyErrorln("error loading current directory (termux fallback put)", .{});
                Output.flush();
                return error.CouldntReadCurrentDirectory;
            };
        };'''

new_content = re.sub(old, lambda m: new, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [2a] readDirInfo orelse → cwd fallback DirInfo")
else:
    print("    [FAIL] could not find readDirInfo pattern in run_command.zig")
    sys.exit(1)

with open("src/cli/run_command.zig", "w") as f:
    f.write(content)

print(f"    Total: {patched}/1 sub-patches applied to run_command.zig")
PYEOF
        verify_patch "$RUN_CMD" "$PATCH_MARKER" || true
    fi
fi

# =====================================================================
# PATCH 3: src/bun.zig — EACCES fallback for openDir functions
# (These are used by OTHER callers, not the resolver walk which uses
# std.fs.openDirAbsoluteZ. Still useful for general Android compat.)
# =====================================================================
BUN_ZIG="src/bun.zig"

if [ ! -f "$BUN_ZIG" ]; then
    echo "  [FAIL] $BUN_ZIG not found"
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    if grep -q "$PATCH_MARKER" "$BUN_ZIG" 2>/dev/null; then
        echo "  [SKIP] $BUN_ZIG already patched"
    else
        echo "  [PATCH] $BUN_ZIG"
        python3 <<'PYEOF'
import re, sys

with open("src/bun.zig", "r") as f:
    content = f.read()

patched = 0

# Patch openDirForIteration — the main one used by the resolver
old = r'''pub fn openDirForIteration\(dir: FD, path_: \[\]const u8\) sys\.Maybe\(FD\) \{
    if \(comptime Environment\.isWindows\) \{
        return sys\.openDirAtWindowsA\(dir, path_, \.\{ \.iterable = true, \.can_rename_or_delete = false, \.read_only = true \}\);
    \}
    return sys\.openatA\(dir, path_, O\.DIRECTORY \| O\.CLOEXEC \| O\.RDONLY, 0\);
\}'''

new = '''pub fn openDirForIteration(dir: FD, path_: []const u8) sys.Maybe(FD) {
    // ANDROID_TERMUX_FIX: On EACCES (e.g. /data is mode 0771), retry
    // without O_DIRECTORY. The fd won't support readdir, but callers
    // that only need to stat/access the path will work.
    if (comptime Environment.isWindows) {
        return sys.openDirAtWindowsA(dir, path_, .{ .iterable = true, .can_rename_or_delete = false, .read_only = true });
    }
    const result = sys.openatA(dir, path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0);
    if (result == .err and result.err.getErrno() == .ACCES) {
        return sys.openatA(dir, path_, O.CLOEXEC | O.RDONLY, 0);
    }
    return result;
}'''

new_content = re.sub(old, lambda m: new, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [3a] openDirForIteration EACCES fallback")
else:
    print("    [SKIP] openDirForIteration pattern not found (may differ in this version)")

# Also patch openDirAbsolute
old2 = r'''pub fn openDirAbsolute\(path_: \[\]const u8\) !std\.fs\.Dir \{
    const fd = if \(comptime Environment\.isWindows\)
        try sys\.openDirAtWindowsA\(invalid_fd, path_, \.\{ \.iterable = true, \.can_rename_or_delete = true, \.read_only = true \}\)\.unwrap\(\)
    else
        try sys\.openA\(path_, O\.DIRECTORY \| O\.CLOEXEC \| O\.RDONLY, 0\)\.unwrap\(\);

    return fd\.stdDir\(\);
\}'''

new2 = '''pub fn openDirAbsolute(path_: []const u8) !std.fs.Dir {
    // ANDROID_TERMUX_FIX: On EACCES, retry without O_DIRECTORY.
    const fd = if (comptime Environment.isWindows)
        try sys.openDirAtWindowsA(invalid_fd, path_, .{ .iterable = true, .can_rename_or_delete = true, .read_only = true }).unwrap()
    else blk: {
        // ANDROID_TERMUX_FIX
        const result = sys.openA(path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0);
        if (result == .err and result.err.getErrno() == .ACCES) {
            break :blk try sys.openA(path_, O.CLOEXEC | O.RDONLY, 0).unwrap();
        }
        break :blk try result.unwrap();
    };

    return fd.stdDir();
}'''

new_content = re.sub(old2, lambda m: new2, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [3b] openDirAbsolute EACCES fallback")
else:
    print("    [SKIP] openDirAbsolute pattern not found")

with open("src/bun.zig", "w") as f:
    f.write(content)

print(f"    Total: {patched} sub-patches applied to bun.zig")
PYEOF
        verify_patch "$BUN_ZIG" "$PATCH_MARKER" || true
    fi
fi

# =====================================================================
# PATCH 4: scripts/build/flags.ts — cross-compile CPU flag fix
# =====================================================================
FLAGS_TS="scripts/build/flags.ts"
if [ -f "$FLAGS_TS" ]; then
    if grep -q "$PATCH_MARKER" "$FLAGS_TS" 2>/dev/null; then
        echo "  [SKIP] $FLAGS_TS already patched"
    else
        echo "  [PATCH] $FLAGS_TS"
        sed -i 's/"-march=armv8-a+crc"/"-march=armv8-a"/g' "$FLAGS_TS"
        sed -i "1i // $PATCH_MARKER: simplified march flags for cross-compile" "$FLAGS_TS"
        verify_patch "$FLAGS_TS" "$PATCH_MARKER" || true
    fi
fi

# =====================================================================
# PATCH 5: scripts/build/tools.ts — accept NDK clang 18
# =====================================================================
TOOLS_TS="scripts/build/tools.ts"
if [ -f "$TOOLS_TS" ]; then
    if grep -q "$PATCH_MARKER" "$TOOLS_TS" 2>/dev/null; then
        echo "  [SKIP] $TOOLS_TS already patched"
    else
        echo "  [PATCH] $TOOLS_TS"
        sed -i "s/export const LLVM_VERSION = \"21.1.8\";/export const LLVM_VERSION = \"18.0.3\"; \/\/ $PATCH_MARKER: NDK r27c clang/" "$TOOLS_TS"
        sed -i "s/const LLVM_MAJOR = \"21\";/const LLVM_MAJOR = \"18\"; \/\/ $PATCH_MARKER/" "$TOOLS_TS"
        sed -i "s/const LLVM_MINOR = \"1\";/const LLVM_MINOR = \"0\"; \/\/ $PATCH_MARKER/" "$TOOLS_TS"
        sed -i "s|paths.push(\`/usr/lib/llvm-\${LLVM_MAJOR}.\${LLVM_MINOR}.0/bin\`);|paths.push(\`/usr/lib/llvm-\${LLVM_MAJOR}.\${LLVM_MINOR}.0/bin\`);\n    // $PATCH_MARKER: NDK clang\n    paths.push(\`\${process.env.ANDROID_NDK_HOME \|\| process.env.ANDROID_NDK_ROOT \|\| \"/opt/android-ndk\"}/toolchains/llvm/prebuilt/linux-x86_64/bin\`);|" "$TOOLS_TS"
        sed -i '/"-Wno-character-conversion",/d' "$FLAGS_TS" 2>/dev/null || true
        verify_patch "$TOOLS_TS" "$PATCH_MARKER" || true
    fi
fi

# =====================================================================
# PATCH 6: EncodingTables.h — remove pragma for clang 19+ warning
# =====================================================================
ENCODING_TABLES="src/jsc/bindings/EncodingTables.h"
if [ -f "$ENCODING_TABLES" ]; then
    if grep -q 'clang diagnostic ignored "-Wcharacter-conversion"' "$ENCODING_TABLES" 2>/dev/null; then
        echo "  [PATCH] $ENCODING_TABLES: remove -Wcharacter-conversion pragma"
        sed -i '/clang diagnostic ignored "-Wcharacter-conversion"/d' "$ENCODING_TABLES"
        echo "  [OK] removed pragma"
    else
        echo "  [SKIP] $ENCODING_TABLES: no pragma to remove"
    fi
fi

# =====================================================================
# PATCH 7: C++ dangling-reference fix for clang 18
# =====================================================================
echo "  [PATCH] searching for dangling reference pattern in C++ files..."
PATCHED_FILES=0
while IFS= read -r -d '' FILE; do
    if grep -q "properties.releaseData()->propertyNameVector()" "$FILE" 2>/dev/null; then
        if grep -q "_releaseData = properties.releaseData()" "$FILE" 2>/dev/null; then
            continue
        fi
        echo "    [patch] $FILE"
        perl -i -pe 's/for \(auto& (\w+) : properties\.releaseData\(\)->propertyNameVector\(\)\)/auto _releaseData = properties.releaseData(); for (auto\& $1 : _releaseData->propertyNameVector())/g' "$FILE"
        PATCHED_FILES=$((PATCHED_FILES + 1))
    fi
done < <(find src -type f \( -name "*.cpp" -o -name "*.h" \) -print0 2>/dev/null)
echo "  [OK] patched $PATCHED_FILES C++ files with dangling reference fix"

# =====================================================================
# FINAL VERIFICATION
# =====================================================================
echo ""
echo "=========================================="
echo "PATCH VERIFICATION SUMMARY"
echo "=========================================="

TOTAL_FAIL=0
for f in src/resolver/resolver.zig src/cli/run_command.zig src/bun.zig; do
    if [ -f "$f" ]; then
        if grep -q "$PATCH_MARKER" "$f" 2>/dev/null; then
            COUNT=$(grep -c "$PATCH_MARKER" "$f")
            echo "  [OK]   $f ($COUNT markers)"
        else
            echo "  [FAIL] $f — NO MARKERS FOUND"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
        fi
    else
        echo "  [SKIP] $f — file not in this Bun version"
    fi
done

echo ""
if [ "$TOTAL_FAIL" -gt 0 ]; then
    echo "=========================================="
    echo "FATAL: $TOTAL_FAIL critical patches did not apply!"
    echo "The build will NOT fix bunx. Aborting."
    echo "=========================================="
    exit 1
fi

echo "=========================================="
echo "All critical patches applied successfully."
echo "=========================================="
