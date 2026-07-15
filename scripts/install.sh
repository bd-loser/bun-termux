#!/data/data/com.termux/files/usr/bin/bash
# bun-termux installer — one-line: curl -fsSL https://bun.sh/termux | bash
set -euo pipefail

DEB_NAME="bun_1.3.14-patched_aarch64.deb"
DOWNLOAD_URL="https://github.com/bd-loser/bun-termux/releases/download/v1.3.14-patched/${DEB_NAME}"
TMP_DEB="$PREFIX/tmp/${DEB_NAME}"

echo "📦 Installing Bun for Termux (aarch64)..."

echo "⬇️  Downloading..."
curl -fsSL -o "$TMP_DEB" "$DOWNLOAD_URL" || {
  echo "❌ Download failed."
  exit 1
}

echo "📋 Installing..."
dpkg -i "$TMP_DEB" 2>/dev/null || {
  echo "❌ Install failed. Try: dpkg -i $TMP_DEB"
  exit 1
}
rm -f "$TMP_DEB"

echo "✅ Done!"
bun --version
