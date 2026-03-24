#!/bin/bash
# Claude Usage Bar — Uninstaller
set -euo pipefail

G='\033[0;32m'; Y='\033[0;33m'; N='\033[0m'
HOOK_PATH="$HOME/.claude/hooks/save-usage-status.sh"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

echo -e "${Y}Removing Claude Usage Bar...${N}"

# Remove plugin from SwiftBar
PLUGIN_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
[ -n "$PLUGIN_DIR" ] && rm -f "$PLUGIN_DIR/claude-usage.5s.sh" && echo "  ✓ Plugin removed"

# Remove hook
rm -f "$HOOK_PATH" && echo "  ✓ Hook removed"

# Remove from settings.json
if [ -f "$CLAUDE_SETTINGS" ]; then
  python3 -c "
import json
from pathlib import Path
p = Path('$CLAUDE_SETTINGS')
s = json.loads(p.read_text())
s.pop('statusLine', None)
p.write_text(json.dumps(s, indent=2))
print('  ✓ settings.json cleaned up')
"
fi

# Clean up tmp files
rm -f /tmp/claude-status-*.json && echo "  ✓ Temp files removed"

echo -e "${G}Done.${N}"
