#!/data/data/com.termux/files/usr/bin/bash
# bun-termux installer — one-line: curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash
set -euo pipefail

REPO="bd-loser/bun-termux"
TMP_DEB="$PREFIX/tmp/bun-termux-latest.deb"

echo "📦 Installing Bun for Termux (aarch64)..."

echo "🔎 Resolving latest release..."
# Always resolve through the releases API: releases are rebuilt in place on
# the same tag, so a hardcoded download URL can keep serving a stale deb
# from GitHub's CDN caches. /releases/latest never points at a prerelease.
DEB_URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | command grep -oE '"browser_download_url":\s*"[^"]+"' \
  | command grep -oE 'https://[^"]+\.deb' \
  | command grep 'aarch64' | command head -1 || true)"

if [ -z "$DEB_URL" ]; then
  echo "❌ Could not resolve the latest release asset." >&2
  echo "   Check https://github.com/$REPO/releases" >&2
  exit 1
fi
echo "⬇️  Downloading $(basename "$DEB_URL")..."
curl -fsSL -o "$TMP_DEB" "$DEB_URL" || {
  echo "❌ Download failed." >&2
  exit 1
}

echo "📋 Installing..."
dpkg -i "$TMP_DEB" 2>/dev/null || {
  echo "❌ Install failed. Try manually: dpkg -i $TMP_DEB" >&2
  exit 1
}
rm -f "$TMP_DEB"

echo "✅ Done!"
bun --version
