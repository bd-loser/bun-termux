#!/data/data/com.termux/files/usr/bin/bash
# bun-fix-network — automatic DNS/proxy workaround for Bun on Termux
#
# Bun reads /etc/resolv.conf, which Termux lacks. Route it through tinyproxy
# so DNS uses Android's resolver instead.

set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TINYPROXY_CONF_DIR="$PREFIX/etc/tinyproxy"
TINYPROXY_CONF="$TINYPROXY_CONF_DIR/tinyproxy.conf"
TINYPROXY_LOG="$PREFIX/var/log/tinyproxy.log"
BASHRC="${HOME}/.bashrc"
PROXY_HOST="127.0.0.1"
PROXY_PORT="8888"
PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
NC=$'\033[0m'

info()  { echo "${BLUE}[i]${NC} $*"; }
ok()    { echo "${GREEN}[+]${NC} $*"; }
warn()  { echo "${YELLOW}[!]${NC} $*"; }
err()   { echo "${RED}[x]${NC} $*" >&2; }

echo "${BLUE}=== bun-fix-network ===${NC}"
echo "Sets up a local HTTP proxy so Bun can reach npm registries on restricted networks."
echo ""

if ! command -v tinyproxy >/dev/null 2>&1; then
    info "tinyproxy not found, installing via pkg..."
    pkg install tinyproxy -y || {
        err "Failed to install tinyproxy. Try: pkg update && pkg install tinyproxy"
        exit 1
    }
else
    ok "tinyproxy already installed"
fi

mkdir -p "$TINYPROXY_CONF_DIR"
mkdir -p "$(dirname "$TINYPROXY_LOG")"

cat > "$TINYPROXY_CONF" <<EOF
# bun-fix-network tinyproxy config
User nobody
Group nogroup
Port ${PROXY_PORT}
Listen ${PROXY_HOST}
Timeout 600
Allow ${PROXY_HOST}
ViaProxyName "tinyproxy"
ConnectPort 443
ConnectPort 80
LogFile ${TINYPROXY_LOG}
LogLevel Info
EOF
ok "wrote tinyproxy config to ${TINYPROXY_CONF}"

pkill -x tinyproxy 2>/dev/null || true
sleep 1

tinyproxy -c "$TINYPROXY_CONF" 2>/dev/null
sleep 2

if ! pgrep -x tinyproxy >/dev/null 2>&1; then
    err "tinyproxy failed to start. Check log: ${TINYPROXY_LOG}"
    err "Last 10 log lines:"
    tail -10 "$TINYPROXY_LOG" 2>/dev/null || true
    exit 1
fi
ok "tinyproxy started on ${PROXY_URL}"

info "testing proxy by reaching registry.npmjs.org..."
if curl -x "$PROXY_URL" -sI --max-time 10 https://registry.npmjs.org/@types/bun 2>&1 | head -1 | grep -q "200"; then
    ok "proxy works — npm registry reachable"
else
    err "proxy test failed. Dumping last log lines:"
    tail -20 "$TINYPROXY_LOG" 2>/dev/null || true
    exit 1
fi

MARKER="# bun-fix-network begin"
if ! grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
    cat >> "$BASHRC" <<EOF

${MARKER}
# Auto-added by bun-fix-network — routes Bun traffic through local tinyproxy
pgrep -x tinyproxy >/dev/null 2>&1 || tinyproxy -c "${TINYPROXY_CONF}" 2>/dev/null &
export HTTPS_PROXY="${PROXY_URL}"
export HTTP_PROXY="${PROXY_URL}"
# bun-fix-network end
EOF
    ok "added proxy env vars to ${BASHRC}"
else
    ok "proxy env vars already in ${BASHRC}"
fi

export HTTPS_PROXY="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"

echo ""
echo "${GREEN}=== Done ===${NC}"
echo ""
echo "Next steps:"
echo "  1. Run: source ~/.bashrc   (or open a new Termux session)"
echo "  2. Test:  bun install"
echo ""
echo "If you want to disable the proxy temporarily:"
echo "  HTTP_PROXY= HTTPS_PROXY= bun install"
echo ""
echo "If you want to remove the fix entirely:"
echo "  pkill tinyproxy && sed -i '/bun-fix-network begin/,/bun-fix-network end/d' ~/.bashrc"
