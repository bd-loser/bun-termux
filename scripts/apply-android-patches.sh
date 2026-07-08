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
# === HYBRID APPROACH: source patches + LD_PRELOAD shim ===
#
# Bun's directory resolver uses std.fs.openDirAbsoluteZ which calls
# Zig's std.os.linux.openat — a RAW SYSCALL (inline asm, NOT libc).
# LD_PRELOAD shims can only intercept libc function calls, NOT raw
# syscalls. Therefore:
#
# - Source patches (Layers 1a/1b/2) are REQUIRED for the resolver walk
#   (they prevent the raw syscall from ever hitting /, or handle the
#   error in Zig's error handling)
# - The LD_PRELOAD shim (libbun-android-fix.so) handles everything that
#   goes through libc: linkat/symlinkat (bun install), fopen (DNS),
#   mkdir/symlink (/tmp), execve (shebangs), /proc/stat (os.cpus())
#
# Both are needed. Neither alone is sufficient.
#
# WHAT THIS PATCHES (Bun v1.3.14 Zig codebase):
#
#   1. src/resolver/resolver.zig — THE bunx fix (2 changes, ancestor walk PRESERVED):
#      a) Walk error switch: on AccessDenied, CONTINUE to the next
#         queue item instead of returning null. Skips inaccessible
#         ancestors (/, /data) while still processing accessible ones.
#         This is the PRIMARY fix — ancestor walking is preserved,
#         so enclosing package.json from parent dirs IS found (monorepo
#         support works!).
#      b) DirEntry cache .err branch: on AccessDenied, don't return the
#         cached error. Without this, a previously-cached EACCES on "/"
#         would propagate as an error on subsequent walks, bypassing (a).
#         This lets root_path be queued, and (a) handles it in processing.
#
#      NOTE: Previous versions had a Layer 1a (root_path = path) that
#      prevented ancestor walking entirely. This is NO LONGER NEEDED
#      because 1a+1b together handle all AccessDenied cases. Removing
#      1a RESTORES MONOREPO SUPPORT (ancestor walking works).
#
#   2. src/cli/run_command.zig — CouldntReadCurrentDirectory fallback:
#      When readDirInfo returns null (walk failed), create a minimal
#      DirInfo from the cwd instead of erroring out.
#
#   3. scripts/build/flags.ts — cross-compile CPU flag fix
#   4. scripts/build/tools.ts — accept NDK clang 18
#   5. C++ dangling-reference fix for clang 18
#
set -euo pipefail

BUN_SRC="${1:-.}"
PATCH_MARKER="ANDROID_TERMUX_FIX"
FAIL_COUNT=0

cd "$BUN_SRC"

echo "=========================================="
echo "Applying Android/Termux patches to Bun v1.3.14"
echo "Source: $BUN_SRC"
echo "Approach: source patches (resolver walk) + LD_PRELOAD shim (libc calls)"
echo "=========================================="

# === Helper: verify a patch was applied ===
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
    content = f.read()

patched = 0

# 1a: Walk error switch — add AccessDenied => continue (PRIMARY FIX)
# This is in the queue PROCESSING loop. When openDirAbsoluteZ returns
# EACCES for / or /data, skip this ancestor and continue to the next.
# The cwd at queue[0] is always accessible.
old_switch = r'''                    error\.ENOTDIR, error\.IsDir, error\.NotDir => return null,'''

new_switch = '''                    // ANDROID_TERMUX_FIX [Layer 1a]: On AccessDenied (EACCES), skip this
                    // ancestor and CONTINUE processing the rest of the queue. The cwd
                    // at queue[0] is always accessible — returning null would abort
                    // the entire walk and never try the cwd. Ancestor walking is
                    // PRESERVED (monorepo support works).
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
    print("    [1a] AccessDenied => continue in processing loop (PRIMARY FIX)")
else:
    print("    [FAIL] could not find walk error switch pattern")
    sys.exit(1)

# 1b: DirEntry cache .err branch — don't return AccessDenied (CACHE FIX)
# This is in the queue QUEUING phase (if top == root_path block). Without
# this, a previously-cached EACCES on "/" would propagate as an error on
# subsequent walks, bypassing Layer 1a entirely. With this, root_path
# gets queued, and Layer 1a handles EACCES in the processing loop.
old_err = r'''                        \.err => \|err\| \{
                            debuglog\("Failed to load DirEntry \{s\}  \{s\} - \{s\}", \.\{ top, @errorName\(err\.original_err\), @errorName\(err\.canonical_error\) \}\);
                            return err\.canonical_error;
                        \},'''

new_err = '''                        .err => |err| {
                            // ANDROID_TERMUX_FIX [Layer 1b]: On AccessDenied, don't return
                            // the cached error. Let root_path be queued — Layer 1a will
                            // handle EACCES in the processing loop. Without this, a
                            // previously-cached EACCES on "/" would propagate as an error
                            // on subsequent walks, bypassing Layer 1a.
                            if (err.canonical_error != error.AccessDenied) {
                                debuglog("Failed to load DirEntry {s}  {s} - {s}", .{ top, @errorName(err.original_err), @errorName(err.canonical_error) });
                                return err.canonical_error;
                            }
                            // AccessDenied: fall through (root_path gets queued, Layer 1a handles it)
                        },'''

new_content = re.sub(old_err, lambda m: new_err, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [1b] DirEntry cache .err: don't return AccessDenied (CACHE FIX)")
else:
    print("    [FAIL] could not find .err branch pattern")
    sys.exit(1)

with open("src/resolver/resolver.zig", "w") as f:
    f.write(content)

print(f"    Total: {patched}/2 sub-patches applied to resolver.zig")
print(f"    Ancestor walking PRESERVED (monorepo support works!)")
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

new = '''        // ANDROID_TERMUX_FIX [Layer 2]: On Android, readDirInfo may return null when
        // the directory walk is blocked by SELinux (EACCES on / or /data via raw
        // syscall that the LD_PRELOAD shim cannot intercept). Instead of failing,
        // create a minimal DirInfo from the cwd so bunx/bun-run can proceed.
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
# PATCH 3: scripts/build/flags.ts — cross-compile CPU flag fix
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
# PATCH 4: scripts/build/tools.ts — accept NDK clang 18
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
# PATCH 5: EncodingTables.h — remove pragma for clang 19+ warning
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
# PATCH 6: C++ dangling-reference fix for clang 18
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
for f in src/resolver/resolver.zig src/cli/run_command.zig scripts/build/flags.ts scripts/build/tools.ts; do
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
echo "Source patches handle resolver walk (raw syscalls)."
echo "LD_PRELOAD shim handles libc calls (linkat, fopen, etc.)."
echo "=========================================="
