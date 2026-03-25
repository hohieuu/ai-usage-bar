#!/bin/bash
# Cursor Usage Bar — Uninstaller
set -euo pipefail

G='\033[0;32m'; Y='\033[0;33m'; M='\033[0;35m'; N='\033[0m'

echo -e "${M}Removing Cursor Usage Bar...${N}"

# Remove plugin from SwiftBar
PLUGIN_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
[ -n "$PLUGIN_DIR" ] && rm -f "$PLUGIN_DIR/cursor-usage.10m.sh" "$PLUGIN_DIR/cursor-usage.30s.sh" && echo "  ✓ Plugin removed"

# Remove config directory (contains token + cache)
if [ -d "$HOME/.cursor-usage-bar" ]; then
  rm -rf "$HOME/.cursor-usage-bar"
  echo "  ✓ Config & cache removed"
fi

echo -e "${G}Done.${N}"
