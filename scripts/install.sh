#!/data/data/com.termux/files/usr/bin/bash
# bun-termux installer — one-line: curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash
set -euo pipefail

REPO="bd-loser/bun-termux"
TMP_DEB="$PREFIX/tmp/bun-termux-latest.deb"

echo "📦 Installing Bun for Termux (aarch64)..."

# --- Resolve latest release ---------------------------------------------------
# Primary: GitHub API. Fallback: web redirect (works when api.github.com
# is blocked by geo-restrictions / ISP firewalls — 403 from certain regions).

resolve_tag_via_redirect() {
  local url
  url="$(curl -fsSI -o /dev/null -w '%{redirect_url}' \
    "https://github.com/$REPO/releases/latest" 2>/dev/null || true)"
  printf '%s' "$url" | command grep -oE '/tag/v[^/]+$' | command sed 's|^/tag/||'
}

echo "🔎 Resolving latest release..."
TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
  | command grep -oE '"tag_name":\s*"[^"]+"' \
  | command sed -E 's/.*"([^"]+)"/\1/' || true)"

if [ -z "$TAG" ]; then
  echo "  API unavailable, trying web redirect fallback..." >&2
  TAG="$(resolve_tag_via_redirect)"
fi

if [ -z "$TAG" ]; then
  echo "❌ Could not resolve the latest release." >&2
  echo "   Check https://github.com/$REPO/releases" >&2
  exit 1
fi

VERSION="${TAG#v}"
DEB="bun_${VERSION}_aarch64.deb"
DEB_URL="https://github.com/$REPO/releases/download/$TAG/$DEB"

echo "⬇️  Downloading $DEB..."
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
