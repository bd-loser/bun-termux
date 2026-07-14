#!/usr/bin/env bash
# build-mte-fix.sh — Build the MTE fix shim for Android/Termux
#
# Usage:
#   bash build-mte-fix.sh [full|simple]
#
#   full   (default) — side-table approach: tracks tags from malloc,
#                      re-applies in free. Most robust.
#   simple            — just strips the tag in free(). Simpler but
#                      only works if scudo accepts untagged pointers.

set -euo pipefail

MODE="${1:-full}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${SCRIPT_DIR}"
OUT_DIR="${SCRIPT_DIR}"
SOURCE="${SRC_DIR}/libbun-mte-fix.c"

if [ "$MODE" = "simple" ]; then
    # Build the simple version (inline source)
    SOURCE="${SRC_DIR}/libbun-mte-fix-simple.c"
    cat > "$SOURCE" <<'EOF'
/* Simple MTE fix: just strip the tag in free() */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void (*real_free)(void *) = NULL;
static void *(*real_malloc)(size_t) = NULL;

static void init_real(void) {
    if (real_free) return;
    real_free = dlsym(RTLD_NEXT, "free");
    real_malloc = dlsym(RTLD_NEXT, "malloc");
}

void *malloc(size_t size) {
    if (!real_malloc) init_real();
    return real_malloc(size);
}

void free(void *ptr) {
    if (!real_free) init_real();
    if (ptr == NULL) { real_free(ptr); return; }
    /* Strip the top byte (MTE tag) */
    void *untagged = (void *)((uintptr_t)ptr & 0x00FFFFFFFFFFFFFFULL);
    real_free(untagged);
}

__attribute__((constructor))
static void init(void) {
    init_real();
    if (getenv("BUN_MTE_FIX_DEBUG")) {
        fprintf(stderr, "[mte-fix-simple] loaded\n");
    }
}
EOF
fi

OUT="${OUT_DIR}/libbun-mte-fix.so"

echo "Building MTE fix shim ($MODE mode)..."
echo "  source: $SOURCE"
echo "  output: $OUT"

# Try clang (preferred), then gcc
if command -v clang &>/dev/null; then
    CC=clang
elif command -v gcc &>/dev/null; then
    CC=gcc
elif command -v cc &>/dev/null; then
    CC=cc
else
    echo "ERROR: no C compiler found (clang/gcc/cc)" >&2
    exit 1
fi

echo "  compiler: $CC"

$CC -shared -fPIC -O2 -Wall -Wextra -o "$OUT" "$SOURCE" -ldl -lpthread

echo ""
echo "✅ Built: $OUT"
echo ""
echo "Usage:"
echo "  LD_PRELOAD=$OUT bun ..."
echo ""
echo "Or add to your launcher:"
echo "  export LD_PRELOAD=\"$OUT:\${LD_PRELOAD:-}\""
echo ""
echo "Debug mode:"
echo "  BUN_MTE_FIX_DEBUG=1 LD_PRELOAD=$OUT bun ..."
