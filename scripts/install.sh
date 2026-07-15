#!/data/data/com.termux/files/usr/bin/bash
# bun-termux installer — one-line: curl -fsSL https://bun.sh/termux | bash
set -euo pipefail

BUN_VERSION="1.3.14"
ARCH="aarch64"
DEB_NAME="bun_${BUN_VERSION}_${ARCH}.deb"
DOWNLOAD_URL="https://github.com/bd-loser/bun-termux/releases/latest/download/${DEB_NAME}"
TMP_DEB="$PREFIX/tmp/${DEB_NAME}"

echo "📦 Installing Bun ${BUN_VERSION} for Termux (${ARCH})..."

# Download
echo "⬇️  Downloading..."
curl -fsSL -o "$TMP_DEB" "$DOWNLOAD_URL" || {
  echo "❌ Download failed. Check your internet connection."
  exit 1
}

# Install
echo "📋 Installing..."
dpkg -i "$TMP_DEB" 2>/dev/null || {
  echo "❌ Installation failed. Try: dpkg -i $TMP_DEB"
  exit 1
}
rm -f "$TMP_DEB"

# Verify
echo "✅ Done!"
bun --version
echo ""
echo "Useful: bun --help | bunx prettier --version"
