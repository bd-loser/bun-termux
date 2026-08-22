#!/data/data/com.termux/files/usr/bin/bash
# launcher-bun.sh — bun launcher for Termux
#
# Execs the patched Bun binary. Since the Bun 1.4 port, all Android fixes
# are source-level (compiled into the binary) — see
# scripts/apply-android-patches.sh. No LD_PRELOAD shim, no termux-exec.
#
# This is the companion to launcher-bunx.sh. The only difference is that
# this launcher does NOT use `exec -a` — argv[0] stays as the binary
# path (ending in "bun"), so Bun runs in normal `bun` mode.
#
# This script is installed at $PREFIX/bin/bun by the deb/pacman
# packaging steps.

set -euo pipefail

BUN_BIN="/data/data/com.termux/files/usr/lib/bun-termux/bun"

if [ ! -x "$BUN_BIN" ]; then
  echo "error: Bun binary not found at $BUN_BIN" >&2
  echo "       Reinstall the bun package: dpkg -i bun_*.deb" >&2
  exit 1
fi

# argv[0] is the binary path (ending in "bun"), so Bun runs in normal
# mode — NOT bunx mode. For bunx mode, use launcher-bunx.sh which uses
# `exec -a "bunx"`.
exec "$BUN_BIN" "$@"
