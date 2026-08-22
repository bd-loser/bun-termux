#!/data/data/com.termux/files/usr/bin/bash
# launcher-bunx.sh — bunx launcher for Termux
#
# WHY THIS FILE EXISTS:
#   Bun detects "bunx mode" by checking if argv[0] ends with "bunx"
#   (isBunX()). A plain `exec bun` would set argv[0] to the binary path
#   (e.g. /data/data/com.termux/files/usr/lib/bun-termux/bun), which ends
#   in "bun" — NOT "bunx" — so Bun would run in normal mode and
#   `bunx <package>` would fail with "Unknown command" or fall through to
#   the bun usage message.
#
#   We use `exec -a bunx` (a bash builtin) to set argv[0]="bunx" while
#   still executing the real Bun binary. This makes the isBunX() check
#   pass, routing to BunxCommand.
#
#   A simple symlink `bunx -> bun` would NOT work here because the `bun`
#   launcher is a shell script that does `exec "$BUN_BIN" "$@"`, which
#   resets argv[0] to the binary path.
#
# NO LD_PRELOAD SHIM:
#   Since the Bun 1.4 port, all Android fixes are source-level (compiled
#   into the binary) — see scripts/apply-android-patches.sh. The shim
#   (libbun-android-fix.so) and termux-exec are no longer used.
#
# This script is installed at $PREFIX/bin/bunx by the deb/pacman
# packaging steps. It must use /data/data/com.termux/files/usr/bin/bash
# (Termux's bash, which supports `exec -a`).

set -euo pipefail

BUN_BIN="/data/data/com.termux/files/usr/lib/bun-termux/bun"

if [ ! -x "$BUN_BIN" ]; then
  echo "error: Bun binary not found at $BUN_BIN" >&2
  echo "       Reinstall the bun package: dpkg -i bun_*.deb" >&2
  exit 1
fi

# CRITICAL: `exec -a "bunx"` sets argv[0] to "bunx" so Bun's isBunX()
# detection returns true. Without this, Bun would run in normal `bun`
# mode and bunx semantics break.
#
# `exec -a` is a bash builtin available in Termux's bash (5+).
exec -a "bunx" "$BUN_BIN" "$@"
