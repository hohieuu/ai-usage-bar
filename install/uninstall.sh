#!/bin/bash
# Claude Usage Bar — Uninstaller
set -euo pipefail

G='\033[0;32m'; Y='\033[0;33m'; N='\033[0m'
HOOK_PATH="$HOME/.claude/hooks/save-usage-status.sh"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CACHE_DIR="$HOME/.claude-usage-bar"

echo -e "${Y}Removing Claude Usage Bar...${N}"

# Remove plugin from SwiftBar (current + legacy)
PLUGIN_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
if [ -n "$PLUGIN_DIR" ]; then
  rm -f "$PLUGIN_DIR/claude-usage.60s.sh" && echo "  ✓ Plugin removed"
  rm -f "$PLUGIN_DIR/claude-usage.5s.sh" 2>/dev/null || true  # legacy
fi

# Remove hook if present
[ -f "$HOOK_PATH" ] && rm -f "$HOOK_PATH" && echo "  ✓ Hook removed"

# Remove statusLine from settings.json if present
if [ -f "$CLAUDE_SETTINGS" ]; then
  python3 -c "
import json
from pathlib import Path
p = Path('$CLAUDE_SETTINGS')
s = json.loads(p.read_text())
if 'statusLine' in s:
    s.pop('statusLine')
    p.write_text(json.dumps(s, indent=2))
    print('  ✓ settings.json cleaned up')
"
fi

# Remove cache dir
[ -d "$CACHE_DIR" ] && rm -rf "$CACHE_DIR" && echo "  ✓ Cache dir removed"

# Clean up tmp files
rm -f /tmp/claude-status-*.json && echo "  ✓ Temp files removed"

echo -e "${G}Done.${N}"
