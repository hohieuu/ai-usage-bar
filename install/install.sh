#!/bin/bash
# Claude Usage Bar — Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/hohieuu/ai-usage-bar/main/install.sh | bash
set -euo pipefail

# Read version from VERSION file (or fallback if not available)
VERSION=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]:-}")/../VERSION" ]; then
  VERSION=$(cat "$(dirname "${BASH_SOURCE[0]:-}")/../VERSION" 2>/dev/null | tr -d '[:space:]')
fi
VERSION="${VERSION:-1.3.0}"
REPO_RAW="https://raw.githubusercontent.com/hohieuu/ai-usage-bar/main"
CACHE_DIR="$HOME/.claude-usage-bar"
VERSION_FILE="$CACHE_DIR/installed_version"
HOOK_PATH="$HOME/.claude/hooks/save-usage-status.sh"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# ── Colors ─────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; N='\033[0m'
info()    { echo -e "${B}[•]${N} $*"; }
success() { echo -e "${G}[✓]${N} $*"; }
warn()    { echo -e "${Y}[!]${N} $*"; }
die()     { echo -e "${R}[✗]${N} $*" >&2; exit 1; }

# ── Detect installed version ───────────────────────────────────────────────
INSTALLED_VERSION=""
IS_UPGRADE=0
IS_LEGACY_UPGRADE=0

if [ -f "$VERSION_FILE" ]; then
  INSTALLED_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || true)
fi

echo ""
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" != "$VERSION" ]; then
  IS_UPGRADE=1
  echo -e "${B}  Claude Usage Bar — Updater          ${N}"
  echo -e "${B}  ${INSTALLED_VERSION} → ${VERSION}                  ${N}"
elif [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" = "$VERSION" ]; then
  echo -e "${B}  Claude Usage Bar — Reinstall        ${N}"
  echo -e "${B}  Already on v${VERSION}                  ${N}"
else
  echo -e "${B}  Claude Usage Bar — Installer        ${N}"
  echo -e "${B}  v${VERSION}                               ${N}"
fi
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""

# ── Check: macOS ───────────────────────────────────────────────────────────
[[ "$OSTYPE" == darwin* ]] || die "macOS only."

# ── Check: dependencies ────────────────────────────────────────────────────
info "Checking dependencies..."
command -v python3 &>/dev/null || die "python3 not found. Install via: brew install python3"
command -v curl    &>/dev/null || die "curl not found."
command -v jq      &>/dev/null || die "jq not found. Install via: brew install jq"
success "Dependencies OK"

# ── Check: Claude Code logged in ──────────────────────────────────────────
info "Checking Claude Code login..."
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('claudeAiOauth',{}).get('accessToken',''))" 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
  die "Not logged in to Claude Code.\n\n  Fix: open a terminal and run:\n\n    claude login\n\n  Then re-run this installer."
fi
success "Logged in to Claude Code"

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
  warn "Open SwiftBar and set this as your plugin folder."
else
  success "Plugin dir: $PLUGIN_DIR"
fi

# ── Clean up ALL existing claude-usage.* files/dirs ───────────────────────
info "Cleaning up any existing claude-usage plugins..."
find "$PLUGIN_DIR" -maxdepth 1 -name "claude-usage.*" -exec rm -rf {} + 2>/dev/null || true
# Legacy: prior versions placed messages.json next to the plugin. It now lives
# in $CACHE_DIR, so remove the old copy to keep the plugin dir to one file.
rm -f "$PLUGIN_DIR/messages.json" 2>/dev/null || true
# Clean up legacy hook if present
if [ -f "$PLUGIN_DIR/claude-usage.5s.sh" ] || [ -f "$PLUGIN_DIR/claude-usage.60s.sh" ]; then
  IS_LEGACY_UPGRADE=1
fi
rm -f "$HOOK_PATH" 2>/dev/null || true
if [ -f "$CLAUDE_SETTINGS" ]; then
  python3 -c "
import json
from pathlib import Path
p = Path('$CLAUDE_SETTINGS')
s = json.loads(p.read_text())
if 'statusLine' in s:
    s.pop('statusLine')
    p.write_text(json.dumps(s, indent=2))
" 2>/dev/null || true
fi
rm -f /tmp/claude-status-*.json 2>/dev/null || true
# Clear rate limit cache on fresh install
rm -f "$HOME/.claude-usage-bar/retry_after" "$HOME/.claude-usage-bar/stale_count" "$HOME/.claude-usage-bar/err429_count" 2>/dev/null || true
success "Cleaned up previous installs"

# ── Install plugin ─────────────────────────────────────────────────────────
info "Installing SwiftBar plugin (v${VERSION})..."
PLUGIN_DEST="$PLUGIN_DIR/claude-usage.3m.sh"

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]:-}")/../bin/claude-usage.3m.sh" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")/../bin" && pwd)"
  cp "$SCRIPT_DIR/claude-usage.3m.sh" "$PLUGIN_DEST"
else
  curl -fsSL "$REPO_RAW/bin/claude-usage.3m.sh" -o "$PLUGIN_DEST"
fi
chmod +x "$PLUGIN_DEST"
success "Plugin installed → $PLUGIN_DEST"

# ── Create cache directory ─────────────────────────────────────────────────
mkdir -p "$CACHE_DIR"

# ── Install messages file (in user data dir, not plugin dir) ───────────────
MESSAGES_DEST="$CACHE_DIR/messages.json"
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]:-}")/../bin/messages.json" ]; then
  cp "$SCRIPT_DIR/messages.json" "$MESSAGES_DEST"
else
  curl -fsSL "$REPO_RAW/bin/messages.json" -o "$MESSAGES_DEST"
fi
success "Messages installed → $MESSAGES_DEST"

# ── Write version ──────────────────────────────────────────────────────────
echo "$VERSION" > "$VERSION_FILE"
success "Version recorded → v${VERSION}"

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
if [ "$IS_LEGACY_UPGRADE" = "1" ]; then
  echo -e "${G}  Upgraded from hook-based → v${VERSION}  ${N}"
  echo -e "${G}  No hook or settings.json needed     ${N}"
elif [ "$IS_UPGRADE" = "1" ]; then
  echo -e "${G}  Updated to v${VERSION}!                   ${N}"
else
  echo -e "${G}  Installation complete! v${VERSION}        ${N}"
fi
echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""
echo "Usage data will appear in your menu bar within 3 minutes."
echo ""
