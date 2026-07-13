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
if [ -f "$SHIM" ]; then
  if [ -z "${LD_PRELOAD:-}" ]; then
    export LD_PRELOAD="$SHIM"
  else
    case ":$LD_PRELOAD:" in
      *":$SHIM:"*) ;;            # already loaded, skip
      *) export LD_PRELOAD="$SHIM:$LD_PRELOAD" ;;
    esac
  fi
fi

# Disable Android's MTE (Memory Tagging Extension) for the Bun process.
# Android 11+ scudo allocator tags heap pointers with the top byte (TBI).
# When Bun's FFI passes these tagged pointers to free(), scudo's MTE
# tag check aborts with SIGABRT. Setting MEMTAG_OPTIONS=off before exec
# tells Bionic's scudo to NOT use MTE tags at all — before the process
# even starts. This is the ONLY way to disable MTE; prctl() in main()
# is too late because scudo has already initialized with MTE enabled.
export MEMTAG_OPTIONS=off

# Exec the patched Bun binary. argv[0] is the binary path (ending in
# "bun"), so Bun runs in normal mode — NOT bunx mode. For bunx mode,
# use launcher-bunx.sh which uses `exec -a "bunx"`.
exec "$BUN_BIN" "$@"
