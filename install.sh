#!/bin/bash
# Claude Usage Bar — Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/hohieuu/ai-usage-bar/main/install.sh | bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/hohieuu/ai-usage-bar/main"
HOOK_PATH="$HOME/.claude/hooks/save-usage-status.sh"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# ── Colors ─────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; N='\033[0m'
info()    { echo -e "${B}[•]${N} $*"; }
success() { echo -e "${G}[✓]${N} $*"; }
warn()    { echo -e "${Y}[!]${N} $*"; }
die()     { echo -e "${R}[✗]${N} $*" >&2; exit 1; }

echo ""
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo -e "${B}  Claude Usage Bar — Installer        ${N}"
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""

# ── Check: macOS ───────────────────────────────────────────────────────────
[[ "$OSTYPE" == darwin* ]] || die "macOS only."

# ── Check: dependencies ────────────────────────────────────────────────────
info "Checking dependencies..."
command -v python3  &>/dev/null || die "python3 not found. Install via: brew install python3"
command -v sqlite3  &>/dev/null || die "sqlite3 not found."
command -v claude   &>/dev/null || die "Claude Code CLI not found. Install from: https://claude.ai/download"

# ── Check: Claude Code version ─────────────────────────────────────────────
CLAUDE_VERSION=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
MIN_VERSION="2.1.81"
version_gte() {
  printf '%s\n%s' "$2" "$1" | sort -V -C
}
if [ -z "$CLAUDE_VERSION" ]; then
  warn "Could not determine Claude Code version — proceeding anyway."
elif ! version_gte "$CLAUDE_VERSION" "$MIN_VERSION"; then
  die "Claude Code $CLAUDE_VERSION is too old. Minimum required: $MIN_VERSION\n  Update with: npm update -g @anthropic-ai/claude-code"
fi
success "Dependencies OK (Claude Code $CLAUDE_VERSION)"

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

# ── Download/copy plugin ───────────────────────────────────────────────────
info "Installing SwiftBar plugin..."
PLUGIN_DEST="$PLUGIN_DIR/claude-usage.5s.sh"

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]:-}")/claude-usage.5s.sh" ]; then
  # Running from cloned repo — copy local files
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)"
  cp "$SCRIPT_DIR/claude-usage.5s.sh" "$PLUGIN_DEST"
  HOOK_SRC="$SCRIPT_DIR/save-usage-status.sh"
else
  # Running via curl | bash — download from GitHub
  curl -fsSL "$REPO_RAW/claude-usage.5s.sh" -o "$PLUGIN_DEST"
  HOOK_SRC=""
fi

chmod +x "$PLUGIN_DEST"
success "Plugin installed → $PLUGIN_DEST"

# ── Install Claude hook ────────────────────────────────────────────────────
info "Installing Claude statusLine hook..."
mkdir -p "$(dirname "$HOOK_PATH")"

if [ -n "$HOOK_SRC" ] && [ -f "$HOOK_SRC" ]; then
  cp "$HOOK_SRC" "$HOOK_PATH"
else
  curl -fsSL "$REPO_RAW/save-usage-status.sh" -o "$HOOK_PATH"
fi
chmod +x "$HOOK_PATH"
success "Hook installed → $HOOK_PATH"

# ── Patch ~/.claude/settings.json ─────────────────────────────────────────
info "Configuring Claude Code settings..."

if [ ! -f "$CLAUDE_SETTINGS" ]; then
  echo '{"statusLine":{"type":"command","command":"'"$HOOK_PATH"'"}}' > "$CLAUDE_SETTINGS"
  success "Created $CLAUDE_SETTINGS"
else
  python3 - "$CLAUDE_SETTINGS" "$HOOK_PATH" <<'PYEOF'
import json, sys, shutil
from pathlib import Path

settings_path = Path(sys.argv[1])
hook_path = sys.argv[2]

# Backup
shutil.copy(settings_path, str(settings_path) + ".bak")

with open(settings_path) as f:
    settings = json.load(f)

existing = settings.get("statusLine", {})
if existing.get("command") == hook_path:
    print("  statusLine already configured, skipping.")
    sys.exit(0)

if existing and existing.get("command") != hook_path:
    print(f"  ⚠️  Existing statusLine found: {existing.get('command')}")
    print(f"  Overwriting with: {hook_path}")

settings["statusLine"] = {"type": "command", "command": hook_path}

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)

print(f"  ✓ settings.json updated")
PYEOF
  success "Claude settings configured"
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

# ── Verify installation ─────────────────────────────────────────────────────
echo -e "${B}Verifying setup...${N}"
echo ""

VERIFY_PASS=0
VERIFY_FAIL=0

if [ -x "$HOOK_PATH" ]; then
  success "Hook installed & executable: $HOOK_PATH"
  ((VERIFY_PASS++))
else
  warn "Hook missing or not executable: $HOOK_PATH"
  ((VERIFY_FAIL++))
fi

if [ -x "$PLUGIN_DEST" ]; then
  success "Plugin installed & executable: $PLUGIN_DEST"
  ((VERIFY_PASS++))
else
  warn "Plugin missing or not executable: $PLUGIN_DEST"
  ((VERIFY_FAIL++))
fi

if [ -f "$CLAUDE_SETTINGS" ]; then
  if grep -q "statusLine" "$CLAUDE_SETTINGS" 2>/dev/null; then
    success "settings.json configured with statusLine hook"
    ((VERIFY_PASS++))
  else
    warn "settings.json exists but statusLine hook not found"
    ((VERIFY_FAIL++))
  fi
else
  warn "settings.json not found"
  ((VERIFY_FAIL++))
fi

if [ -d "$PLUGIN_DIR" ] && [ -w "$PLUGIN_DIR" ]; then
  success "SwiftBar plugin directory writable: $PLUGIN_DIR"
  ((VERIFY_PASS++))
else
  warn "SwiftBar plugin directory not writable: $PLUGIN_DIR"
  ((VERIFY_FAIL++))
fi

echo ""
if [ $VERIFY_FAIL -eq 0 ]; then
  echo -e "${G}All checks passed! ✓${N}"
  echo ""
  echo "Next steps:"
  echo "  1. Restart Claude Code"
  echo "  2. Generate a response"
  echo "  3. Check menu bar for 'CC' usage indicator"
  echo ""
else
  echo -e "${Y}⚠️  ${VERIFY_FAIL} issue(s) detected. Attempting fixes...${N}"
  echo ""

  if [ ! -x "$HOOK_PATH" ]; then
    warn "Fixing hook permissions..."
    chmod +x "$HOOK_PATH" 2>/dev/null && success "✓ Hook fixed" || warn "Could not fix hook"
  fi

  if [ ! -x "$PLUGIN_DEST" ]; then
    warn "Fixing plugin permissions..."
    chmod +x "$PLUGIN_DEST" 2>/dev/null && success "✓ Plugin fixed" || warn "Could not fix plugin"
  fi

  if [ ! -d "$PLUGIN_DIR" ] || [ ! -w "$PLUGIN_DIR" ]; then
    warn "SwiftBar plugin directory permission issue"
    warn "Try: open /Applications/SwiftBar.app"
    warn "Then go to Settings → Plugin Folder and select: $PLUGIN_DIR"
  fi

  echo ""
  info "If issues persist, run for debugging:"
  echo "  bash show-usage.sh           # See live usage data"
  echo "  cat $CLAUDE_SETTINGS   # Check hook config"
  echo "  ls -la $PLUGIN_DIR/   # Check plugin files"
fi

echo ""
