#!/usr/bin/env bash
# build-shim.sh — compile libbun-android-fix.so for Termux (aarch64 Bionic)
#
# Runs inside the ghcr.io/termux/package-builder container, which has
# aarch64-linux-android-clang (NDK r27c) for cross-compiling to Android.
#
# Output: dist/libbun-android-fix.so (ELF 64-bit aarch64, Bionic-linked)

set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="$ROOT_DIR/src/libbun-android-fix.c"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
OUT="$OUT_DIR/libbun-android-fix.so"

mkdir -p "$OUT_DIR"

# Try NDK clang first (preferred — produces Bionic-compatible binary)
CC=""
for candidate in \
    aarch64-linux-android-clang \
    aarch64-linux-android29-clang \
    $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang \
    /opt/android-ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang
do
    if command -v "$candidate" >/dev/null 2>&1 || [ -x "$candidate" ]; then
        CC="$candidate"
        break
    fi
done

# Fallback: try Termux's clang directly (when running on Termux itself)
if [ -z "$CC" ] && command -v clang >/dev/null 2>&1; then
    CC="clang"
fi

if [ -z "$CC" ]; then
    echo "ERROR: No aarch64 Android cross-compiler found"
    echo "Install Android NDK or run on Termux"
    exit 1
fi

echo "Using CC: $CC"
echo "Compiling: $SRC"
echo "Output:    $OUT"

# Compile flags:
# -shared              → shared library (.so)
# -fPIC                → position-independent code
# -O2                  → optimization
# -Wall -Wextra        → warnings
# -Wno-nonnull-compare → silence (pathname ? ... : ...) checks on nonnull params
# -ldl                 → link against libdl (for dlsym)
$CC -shared -fPIC -O2 -Wall -Wextra -Wno-nonnull-compare \
    -o "$OUT" \
    "$SRC" \
    -ldl

# Verify the output is a valid ELF
if command -v file >/dev/null 2>&1; then
    echo ""
    echo "=== Built artifact ==="
    file "$OUT"
    ls -la "$OUT"
fi

echo ""
echo "Done."
