#!/data/data/com.termux/files/usr/bin/bash
# Launch the source-patched Bun binary in normal mode.

set -euo pipefail

BUN_BIN="/data/data/com.termux/files/usr/lib/bun-termux/bun"

if [ ! -x "$BUN_BIN" ]; then
  echo "error: Bun binary not found at $BUN_BIN" >&2
  echo "       Reinstall the bun package: dpkg -i bun_*.deb" >&2
  exit 1
fi

exec "$BUN_BIN" "$@"
