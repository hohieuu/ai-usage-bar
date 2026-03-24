#!/bin/bash
# Cursor Usage Bar — Installer (zero-config)
# Usage: bash cursor-install.sh
# Token auto-extracted from Cursor's local DB — no manual setup needed.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/hohieuu/ai-usage-bar/main"
CURSOR_DB="$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

# ── Colors ─────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; M='\033[0;35m'; N='\033[0m'
info()    { echo -e "${B}[•]${N} $*"; }
success() { echo -e "${G}[✓]${N} $*"; }
warn()    { echo -e "${Y}[!]${N} $*"; }
die()     { echo -e "${R}[✗]${N} $*" >&2; exit 1; }

echo ""
echo -e "${M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo -e "${M}  Cursor Usage Bar — Installer         ${N}"
echo -e "${M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""

# ── Check: macOS ───────────────────────────────────────────────────────────
[[ "$OSTYPE" == darwin* ]] || die "macOS only."

# ── Check: dependencies ────────────────────────────────────────────────────
info "Checking dependencies..."
command -v python3  &>/dev/null || die "python3 not found. Install via: brew install python3"
command -v curl     &>/dev/null || die "curl not found."
command -v sqlite3  &>/dev/null || die "sqlite3 not found."
[ -f "$CURSOR_DB" ] || die "Cursor not installed or never logged in."
success "Dependencies OK"

# ── Verify Cursor auth token works ────────────────────────────────────────
info "Verifying Cursor auth..."
ACCESS_TOKEN=$(sqlite3 "$CURSOR_DB" \
  "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';" 2>/dev/null || true)
[ -z "$ACCESS_TOKEN" ] && die "Not logged in to Cursor. Open Cursor and sign in first."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://api2.cursor.sh/auth/usage" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
  success "Cursor API verified (Bearer token from local DB)"
else
  die "Cursor API returned HTTP $HTTP_CODE. Try restarting Cursor to refresh the token."
fi

# ── Check / install SwiftBar ───────────────────────────────────────────────
info "Checking SwiftBar..."
if ! ls /Applications/SwiftBar.app &>/dev/null; then
  if command -v brew &>/dev/null; then
    info "Installing SwiftBar via Homebrew..."
    brew install --cask swiftbar
  else
    die "SwiftBar not found. Install from https://swiftbar.app or: brew install --cask swiftbar"
  fi
fi
success "SwiftBar found"

# ── Get SwiftBar plugin directory ──────────────────────────────────────────
info "Finding SwiftBar plugin directory..."
PLUGIN_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
if [ -z "$PLUGIN_DIR" ]; then
  PLUGIN_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"
  mkdir -p "$PLUGIN_DIR"
  warn "SwiftBar plugin dir not configured — using default: $PLUGIN_DIR"
else
  success "Plugin dir: $PLUGIN_DIR"
fi

# ── Create cache directory ────────────────────────────────────────────────
mkdir -p "$HOME/.cursor-usage-bar"

# ── Download/copy plugin ───────────────────────────────────────────────────
info "Installing SwiftBar plugin..."
PLUGIN_DEST="$PLUGIN_DIR/cursor-usage.10m.sh"

# Remove old versions if present
rm -f "$PLUGIN_DIR/cursor-usage.5s.sh" "$PLUGIN_DIR/cursor-usage.30s.sh" 2>/dev/null

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]:-}")/cursor-usage.10m.sh" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)"
  cp "$SCRIPT_DIR/cursor-usage.10m.sh" "$PLUGIN_DEST"
else
  curl -fsSL "$REPO_RAW/cursor-usage.10m.sh" -o "$PLUGIN_DEST"
fi

chmod +x "$PLUGIN_DEST"
success "Plugin installed → $PLUGIN_DEST"

# ── Fetch initial data ────────────────────────────────────────────────────
info "Fetching current usage..."
CACHE_FILE="$HOME/.cursor-usage-bar/cache.json"
USAGE_JSON=$(curl -s --max-time 10 \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://api2.cursor.sh/auth/usage" 2>/dev/null || true)

if [ -n "$USAGE_JSON" ]; then
  echo "$USAGE_JSON" > "$CACHE_FILE"
  # Show current usage
  python3 -c "
import json
d = json.loads('''$USAGE_JSON''')
total = 0; limit = 0
for k, v in d.items():
    if isinstance(v, dict) and 'numRequests' in v:
        total += v['numRequests']
        mx = v.get('maxRequestUsage') or 0
        if mx > limit: limit = mx
print(f'  {total} / {limit} premium requests this month')
" 2>/dev/null
fi

# ── Launch / refresh SwiftBar ──────────────────────────────────────────────
info "Refreshing SwiftBar..."
if pgrep -x SwiftBar &>/dev/null; then
  open "swiftbar://refreshallplugins" 2>/dev/null || true
  success "SwiftBar refreshed"
else
  open /Applications/SwiftBar.app
  success "SwiftBar launched"
fi

# ── Done ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo -e "${G}  Installation complete! 🎉           ${N}"
echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""
echo "  Menu bar shows: ⌘ X/Y (requests / limit)"
echo "  Click for: progress, pace, projection, models"
echo "  Refreshes every 10 minutes"
echo ""
echo "  No config needed — token reads from Cursor automatically."
echo "  Uninstall: bash cursor-uninstall.sh"
echo ""
