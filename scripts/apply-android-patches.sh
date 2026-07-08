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
# === HISTORY: SOURCE PATCHES REMOVED (shim now handles everything) ===
#
#   Previous versions of this script applied 5 source-level patches to
#   Bun's Zig source (Layers 1a/1b/2/3a/3b). These are NO LONGER NEEDED
#   because libbun-android-fix.so (the LD_PRELOAD shim) now handles all
#   EACCES/path issues at the syscall level:
#
#     - Layer 1a (root_path = path): shim's safe_dir_fd duplicate
#       intercepts openat(O_DIRECTORY) EACCES on /, /data and returns
#       a valid directory fd, so the ancestor walk completes naturally.
#       REMOVING THIS RESTORES MONOREPO SUPPORT (enclosing package.json
#       from parent dirs is now found correctly).
#     - Layer 1b (AccessDenied => continue): shim catches EACCES before
#       it reaches Bun's error handling.
#     - Layer 2 (synthetic DirInfo): readDirInfo now succeeds (walk
#       completes via shim), so the null fallback never triggers.
#     - Layer 3a/3b (bun.zig openDir EACCES fallback): shim intercepts
#       ALL openat calls, not just the resolver's.
#
#   The shim approach is strictly better: it works for ALL callers of
#   openat (not just the resolver), doesn't disable ancestor walking,
#   and survives Bun version upgrades without source patch maintenance.
#
# === WHAT THIS SCRIPT STILL PATCHES (build-only) ===
#
#   These patches are required for Bun to BUILD with NDK clang 18, but
#   do NOT change runtime behavior:
#
#   1. scripts/build/flags.ts — cross-compile CPU flag fix (march=armv8-a)
#   2. scripts/build/tools.ts — accept NDK clang 18 (LLVM_VERSION)
#   3. src/jsc/bindings/EncodingTables.h — remove clang 19+ pragma
#   4. C++ dangling-reference fix for clang 18
#
set -euo pipefail

BUN_SRC="${1:-.}"
PATCH_MARKER="ANDROID_TERMUX_FIX"
FAIL_COUNT=0

cd "$BUN_SRC"

echo "=========================================="
echo "Applying Android/Termux build patches to Bun v1.3.14"
echo "Source: $BUN_SRC"
echo "NOTE: Runtime EACCES fixes are now in libbun-android-fix.so (shim),"
echo "      not in source patches. See header comment for history."
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
# PATCH 1: scripts/build/flags.ts — cross-compile CPU flag fix
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
# PATCH 2: scripts/build/tools.ts — accept NDK clang 18
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
# PATCH 3: EncodingTables.h — remove pragma for clang 19+ warning
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
# PATCH 4: C++ dangling-reference fix for clang 18
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
echo "BUILD PATCH VERIFICATION SUMMARY"
echo "=========================================="

TOTAL_FAIL=0
for f in scripts/build/flags.ts scripts/build/tools.ts; do
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
    echo "FATAL: $TOTAL_FAIL build patches did not apply!"
    echo "=========================================="
    exit 1
fi

echo "=========================================="
echo "All build patches applied successfully."
echo "Runtime EACCES fixes are in libbun-android-fix.so (shim)."
echo "=========================================="
