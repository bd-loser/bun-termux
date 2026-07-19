#!/data/data/com.termux/files/usr/bin/bash
# launcher-bun.sh — bun launcher for Termux
#
# Loads the libbun-android-fix.so LD_PRELOAD shim (which intercepts
# EACCES-returning syscalls on Android SELinux and provides fallbacks)
# and then execs the patched Bun binary.
#
# This is the companion to launcher-bunx.sh. The only difference is that
# this launcher does NOT use `exec -a` — argv[0] stays as the binary
# path (ending in "bun"), so Bun runs in normal `bun` mode.
#
# This script is installed at $PREFIX/bin/bun by the deb/pacman
# packaging steps.

set -euo pipefail

SHIM="/data/data/com.termux/files/usr/lib/bun-termux/libbun-android-fix.so"
BUN_BIN="/data/data/com.termux/files/usr/lib/bun-termux/bun"

if [ ! -x "$BUN_BIN" ]; then
  echo "error: Bun binary not found at $BUN_BIN" >&2
  echo "       Reinstall the bun package: dpkg -i bun_*.deb" >&2
  exit 1
fi

# Load the LD_PRELOAD shim if it exists (built by build-shim.sh / CI).
# Don't double-load if it's already in LD_PRELOAD.
add_preload() {
  local lib="$1"
  if [ -f "$lib" ]; then
    if [ -z "${LD_PRELOAD:-}" ]; then
      export LD_PRELOAD="$lib"
    else
      case ":$LD_PRELOAD:" in
        *":$lib:"*) ;;            # already loaded, skip
        *) export LD_PRELOAD="$lib:$LD_PRELOAD" ;;
      esac
    fi
  fi
}

# Load the android-fix shim (SELinux syscall interception, path translation).
# Scudo heap tagging is disabled inside the patched binary itself via
# mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, NONE) at the top of main() —
# see PATCH 11 in scripts/apply-android-patches.sh. No LD_PRELOAD MTE
# shim or MEMTAG_OPTIONS env var is required.
add_preload "$SHIM"

# Exec the patched Bun binary. argv[0] is the binary path (ending in
# "bun"), so Bun runs in normal mode — NOT bunx mode. For bunx mode,
# use launcher-bunx.sh which uses `exec -a "bunx"`.
exec "$BUN_BIN" "$@"
