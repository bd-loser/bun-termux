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

# Load the MTE fix shim FIRST (before the android-fix shim) so that
# malloc/free interception happens before any other LD_PRELOAD library
# touches the heap. The MTE fix strips tags from malloc's return values
# and re-applies them in free(), so Bun's FFI never sees tagged pointers.
#
# Build it with: bash src/mte-fix/build-mte-fix.sh full
MTE_FIX="/data/data/com.termux/files/usr/lib/bun-termux/libbun-mte-fix.so"
add_preload "$MTE_FIX"

# Load the android-fix shim (SELinux syscall interception, path translation)
add_preload "$SHIM"

# Disable Android's MTE (Memory Tagging Extension) for the Bun process.
# Android 11+ scudo allocator tags heap pointers with the top byte (TBI).
# When Bun's FFI passes these tagged pointers to free(), scudo's MTE
# tag check aborts with SIGABRT. Setting MEMTAG_OPTIONS=off before exec
# tells Bionic's scudo to NOT use MTE tags at all — before the process
# even starts.
#
# NOTE: On some Android versions / devices, MEMTAG_OPTIONS=off does NOT
# actually disable MTE (the kernel or ELF notes force it on). In that
# case, the libbun-mte-fix.so shim above handles the tag stripping /
# re-application at the malloc/free boundary, which works regardless
# of whether MEMTAG_OPTIONS is respected.
export MEMTAG_OPTIONS=off

# Exec the patched Bun binary. argv[0] is the binary path (ending in
# "bun"), so Bun runs in normal mode — NOT bunx mode. For bunx mode,
# use launcher-bunx.sh which uses `exec -a "bunx"`.
exec "$BUN_BIN" "$@"
