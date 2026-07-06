#!/usr/bin/env bash
# Package Bun as DEB for Termux
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="${VERSION:-${1:-1.3.9}}"
ARCH="${ARCH:-aarch64}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

STAGED_BIN="${STAGED_BIN:-$ROOT_DIR/runtime/bun}"
DEB_ROOT="$ROOT_DIR/packaging/dpkg/work"
OUT_DIR="$ROOT_DIR/packaging/dpkg"
OUT_FILE="$OUT_DIR/bun_${VERSION}_${ARCH}.deb"

command -v dpkg-deb >/dev/null 2>&1 || { echo "Error: dpkg-deb not found"; exit 1; }
mkdir -p "$OUT_DIR"
rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN"
mkdir -p "$DEB_ROOT$PREFIX/bin"
mkdir -p "$DEB_ROOT$PREFIX/lib/bun-termux"
chmod 755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN"

if [[ ! -f "$STAGED_BIN" ]]; then
  echo "Error: Bun binary not found: $STAGED_BIN"
  exit 1
fi

echo "Packaging Bun DEB v$VERSION"

# Install binary
install -m755 "$STAGED_BIN" "$DEB_ROOT$PREFIX/lib/bun-termux/bun"

# Create launcher
cat > "$DEB_ROOT$PREFIX/bin/bun" << 'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
exec grun "$PREFIX/lib/bun-termux/bun" "$@"
LAUNCHER
chmod 755 "$DEB_ROOT$PREFIX/bin/bun"

# Create control file
cat > "$DEB_ROOT/DEBIAN/control" << EOF
Package: bun
Version: $VERSION
Architecture: $ARCH
Maintainer: Hope2333
Section: utils
Priority: optional
Description: Bun runtime for Termux (glibc-runner wrapper)
Depends: glibc-runner, bash, ncurses
EOF

# Calculate installed size
INSTALLED_SIZE=$(du -sk "$DEB_ROOT" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >> "$DEB_ROOT/DEBIAN/control"

# Create postinst
cat > "$DEB_ROOT/DEBIAN/postinst" << 'POSTINST'
#!/usr/bin/env bash
set -e
echo "Bun for Termux installed!"
echo "Usage: bun --version"
exit 0
POSTINST
chmod 755 "$DEB_ROOT/DEBIAN/postinst"

# Build package
dpkg-deb --build "$DEB_ROOT" "$OUT_FILE"
echo "DEB package created: $OUT_FILE"
