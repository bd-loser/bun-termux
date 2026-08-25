#!/data/data/com.termux/files/usr/bin/bash
# Bun selects bunx mode from argv[0], so the launcher requires Bash's exec -a.

set -euo pipefail

BUN_BIN="/data/data/com.termux/files/usr/lib/bun-termux/bun"

if [ ! -x "$BUN_BIN" ]; then
  echo "error: Bun binary not found at $BUN_BIN" >&2
  echo "       Reinstall the bun package: dpkg -i bun_*.deb" >&2
  exit 1
fi

exec -a "bunx" "$BUN_BIN" "$@"
