#!/data/data/com.termux/files/usr/bin/bash
# launcher-bunx.sh — bunx launcher for Termux
#
# WHY THIS FILE EXISTS:
#   Bun detects "bunx mode" by checking if argv[0] ends with "bunx"
#   (see src/cli/cli.zig, function isBunX()). A plain `exec bun` would
#   set argv[0] to the binary path (e.g. /data/data/com.termux/files/usr/
#   lib/bun-termux/bun), which ends in "bun" — NOT "bunx" — so Bun would
#   run in normal mode and `bunx <package>` would fail with "Unknown
#   command" or fall through to the bun usage message.
#
#   We use `exec -a bunx` (a bash builtin) to set argv[0]="bunx" while
#   still executing the real Bun binary. This makes Bun's isBunX() check
#   pass, routing to BunxCommand.exec().
#
#   A simple symlink `bunx -> bun` would NOT work here because the `bun`
#   launcher is a shell script that does `exec "$BUN_BIN" "$@"`, which
#   resets argv[0] to the binary path.
#
# LD_PRELOAD SHIM:
#   libbun-android-fix.so intercepts syscalls that fail with EACCES on
#   Android SELinux (linkat, symlinkat, openat with O_DIRECTORY on /
#   and /data/, etc.) and provides copy/retry fallbacks. We load it
#   here for the same reasons as the `bun` launcher — bunx runs the
#   same installer code path that needs these fallbacks.
#
# This script is installed at $PREFIX/bin/bunx by the deb/pacman
# packaging steps. It must use /data/data/com.termux/files/usr/bin/bash
# (Termux's bash, which supports `exec -a`).

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

# Load the android-fix shim. Scudo heap tagging is disabled inside the
# patched binary itself via mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, NONE)
# at the top of main() — see PATCH 11 in scripts/apply-android-patches.sh.
# No LD_PRELOAD MTE shim or MEMTAG_OPTIONS env var is required.
add_preload "$SHIM"

# CRITICAL: `exec -a "bunx"` sets argv[0] to "bunx" so Bun's isBunX()
# detection (endsWithComptime(argv0, "bunx")) returns true. Without
# this, Bun would run in normal `bun` mode and bunx semantics break.
#
# `exec -a` is a bash builtin available in Termux's bash (5+).
exec -a "bunx" "$BUN_BIN" "$@"
