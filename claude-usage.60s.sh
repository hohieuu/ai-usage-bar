#!/bin/bash
# Claude Code Usage Bar — SwiftBar Plugin
# Version: 2.0.0
# Uses GET /api/oauth/usage directly — no hook or /tmp files required.
# Updated: 2026-03-25
# Repo: https://github.com/hohieuu/ai-usage-bar
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>false</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>false</swiftbar.hideSwiftBar>
# <swiftbar.title>Claude Usage</swiftbar.title>

# ── Theme: always dark ─────────────────────────────────────────────────────
C_GOOD="#00cc44";  C_WARN="#ffaa00";  C_BAD="#ff4444"
C_DIM="#aaaaaa";   C_INFO="#6699ff";  C_FG="#ffffff"
C_TIME="#44aaff"

# ── Cache paths ────────────────────────────────────────────────────────────
CACHE_DIR="$HOME/.claude-usage-bar"
CACHE_FILE="$CACHE_DIR/cache.json"
RETRY_FILE="$CACHE_DIR/retry_after"
HEADERS_TMP="/tmp/claude-usage-api-headers.tmp"
PLUGIN_PATH="${BASH_SOURCE[0]}"
mkdir -p "$CACHE_DIR"

# ── Force-refresh flag (set by Refresh button) ─────────────────────────────
FORCE_REFRESH=0
if [ "${1:-}" = "--force" ]; then
  FORCE_REFRESH=1
  rm -f "$RETRY_FILE"
fi

# ── Get OAuth token from macOS Keychain ────────────────────────────────────
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('claudeAiOauth',{}).get('accessToken',''))" 2>/dev/null)

# ── Cache age (seconds since last successful fetch) ────────────────────────
CACHE_AGE=999999
if [ -f "$CACHE_FILE" ]; then
  CACHE_MTIME=$(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  CACHE_AGE=$(( $(date +%s) - CACHE_MTIME ))
fi

# ── Fetch from API (with rate-limit + 60s TTL guard) ──────────────────────
fetch_usage() {
  [ -z "$TOKEN" ] && return 1

  # Skip if cache is fresh and not a forced refresh
  if [ "$FORCE_REFRESH" = "0" ] && [ "$CACHE_AGE" -lt 60 ] 2>/dev/null; then
    return 1
  fi

  # Respect Retry-After if we were previously 429'd
  if [ -f "$RETRY_FILE" ]; then
    RETRY_TS=$(cat "$RETRY_FILE" 2>/dev/null)
    NOW=$(date +%s)
    if [ -n "$RETRY_TS" ] && [ "$NOW" -lt "$RETRY_TS" ] 2>/dev/null; then
      return 1  # Still in backoff — use cache
    fi
    rm -f "$RETRY_FILE"
  fi

  RESPONSE=$(curl -s -D "$HEADERS_TMP" \
    -H "Authorization: Bearer $TOKEN" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Content-Type: application/json" \
    --max-time 5 \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

  HTTP_CODE=$(awk 'NR==1{print $2}' "$HEADERS_TMP" 2>/dev/null)

  if [ "$HTTP_CODE" = "200" ]; then
    echo "$RESPONSE" > "$CACHE_FILE"
    rm -f "$RETRY_FILE"
    echo "$RESPONSE"
    return 0
  elif [ "$HTTP_CODE" = "429" ]; then
    RETRY_SECS=$(grep -i "^retry-after:" "$HEADERS_TMP" 2>/dev/null | awk '{print $2}' | tr -d '\r')
    if [ -n "$RETRY_SECS" ]; then
      echo $(( $(date +%s) + RETRY_SECS )) > "$RETRY_FILE"
    fi
  fi
  return 1
}

# ── Load data: try API first, fall back to cache ───────────────────────────
API_DATA=$(fetch_usage 2>/dev/null)
if [ -z "$API_DATA" ] && [ -f "$CACHE_FILE" ]; then
  API_DATA=$(cat "$CACHE_FILE" 2>/dev/null)
  USING_CACHE=1
fi


# ── Parse usage data ───────────────────────────────────────────────────────
_TMP_VARS=$(mktemp)
if [ -n "$API_DATA" ]; then
  python3 - "$API_DATA" > "$_TMP_VARS" 2>/dev/null <<'PYEOF'
import json, sys
try:
    d = json.loads(sys.argv[1])
    def e(v): return str(v) if v not in ('', None) else ''
    five = d.get('five_hour') or {}
    week = d.get('seven_day') or {}
    print("FIVE_PCT="    + e(five.get('utilization')))
    print("FIVE_RESETS=" + e(five.get('resets_at')))
    print("SEVEN_PCT="   + e(week.get('utilization')))
    print("SEVEN_RESETS="+ e(week.get('resets_at')))
except: pass
PYEOF
  source "$_TMP_VARS"
fi
rm -f "$_TMP_VARS"

# ── Format reset countdowns (ISO 8601 input) ───────────────────────────────
fmt_reset() {
  local iso="$1" days="$2"
  [ -z "$iso" ] && echo "?" && return
  python3 -c "
from datetime import datetime, timezone
try:
    dt = datetime.fromisoformat('$iso')
    now = datetime.now(timezone.utc)
    secs = max(int((dt - now).total_seconds()), 0)
    h, r = divmod(secs, 3600); m = r // 60
    local_dt = dt.astimezone()
    if $days and h >= 24:
        d = h // 24; h = h % 24
        print(f'{d}d {h}h  ·  {local_dt.strftime(\"%a %H:%M\")}')
    else:
        print(f'{h}h {m}m  ·  {local_dt.strftime(\"%H:%M\")}')
except Exception as ex:
    print('?')
" 2>/dev/null || echo "?"
}

FIVE_RESET_STR=$(fmt_reset "$FIVE_RESETS" 0)
SEVEN_RESET_STR=$(fmt_reset "$SEVEN_RESETS" 1)

# ── Compute time-window progress ───────────────────────────────────────────
time_pct() {
  local iso="$1" window_hours="$2"
  [ -z "$iso" ] && return
  python3 -c "
from datetime import datetime, timezone
try:
    resets = datetime.fromisoformat('$iso')
    now = datetime.now(timezone.utc)
    start = resets.timestamp() - $window_hours * 3600
    elapsed = max(now.timestamp() - start, 0)
    pct = min(elapsed / ($window_hours * 3600) * 100, 100)
    print(f'{pct:.1f}')
except: pass
" 2>/dev/null
}

FIVE_TIME_PCT=$(time_pct "$FIVE_RESETS" 5)
SEVEN_TIME_PCT=$(time_pct "$SEVEN_RESETS" 168)

# ── Pick bar color based on usage ─────────────────────────────────────────
if [ -n "$FIVE_PCT" ]; then
  FIVE_INT=$(python3 -c "print(int(float('$FIVE_PCT')))" 2>/dev/null)
  if   [ "${FIVE_INT:-0}" -ge 80 ] 2>/dev/null; then BAR_COLOR="$C_BAD"
  elif [ "${FIVE_INT:-0}" -ge 50 ] 2>/dev/null; then BAR_COLOR="$C_WARN"
  else BAR_COLOR="$C_GOOD"
  fi
  LABEL="Claude ${FIVE_INT}%"
  [ "${USING_CACHE:-0}" = "1" ] && LABEL="Claude ${FIVE_INT}% ·"
else
  FIVE_INT=0; BAR_COLOR="$C_DIM"; LABEL="Claude --"
fi

# ── Progress bar helper (10 chars) ────────────────────────────────────────
make_bar() {
  python3 -c "
p = min(max(int(float('${1:-0}')), 0), 100)
filled = round(p / 10)
print('█' * filled + '░' * (10 - filled) + f' {p}%')
" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════
# OUTPUT
# ══════════════════════════════════════════════════════════════════════════
echo "$LABEL | font=Menlo-Bold size=13 color=$BAR_COLOR"
echo "---"

# ── Header ─────────────────────────────────────────────────────────────────
if [ "${USING_CACHE:-0}" = "1" ]; then
  echo "Claude Usage  [cached] | font=Menlo-Bold size=12 color=$C_DIM,$C_DIM"
else
  echo "Claude Usage | font=Menlo-Bold size=12 color=$BAR_COLOR,$BAR_COLOR"
fi

# ── 5h window ──────────────────────────────────────────────────────────────
if [ -n "$FIVE_PCT" ] && [ -n "$FIVE_RESETS" ]; then
  echo "  5h  $(make_bar "$FIVE_PCT") | font=Menlo size=12 color=$BAR_COLOR,$BAR_COLOR"
  if [ -n "$FIVE_TIME_PCT" ]; then
    FIVE_TIME_INT=$(python3 -c "print(int(float('$FIVE_TIME_PCT')))" 2>/dev/null)
    if   [ "${FIVE_TIME_INT:-0}" -ge 90 ] 2>/dev/null; then TIME_COLOR="$C_BAD"
    elif [ "${FIVE_TIME_INT:-0}" -ge 75 ] 2>/dev/null; then TIME_COLOR="$C_WARN"
    else TIME_COLOR="$C_TIME"
    fi
    echo "  ⏱   $(make_bar "$FIVE_TIME_PCT") | font=Menlo size=12 color=$TIME_COLOR,$TIME_COLOR"
  fi
  echo "  Resets  $FIVE_RESET_STR | font=Menlo size=11 color=$C_INFO,$C_INFO"
elif [ -z "$TOKEN" ]; then
  echo "  Not logged in to Claude Code | font=Menlo size=12 color=$C_BAD,$C_BAD"
  echo "  Run: claude login | font=Menlo size=11 color=$C_DIM,$C_DIM"
else
  echo "  Fetching usage... | font=Menlo size=12 color=$C_DIM,$C_DIM"
fi

# ── 7d window ──────────────────────────────────────────────────────────────
if [ -n "$SEVEN_PCT" ]; then
  SEVEN_INT=$(python3 -c "print(int(float('$SEVEN_PCT')))" 2>/dev/null)
  if   [ "${SEVEN_INT:-0}" -ge 80 ] 2>/dev/null; then SEVEN_COLOR="$C_BAD"
  elif [ "${SEVEN_INT:-0}" -ge 50 ] 2>/dev/null; then SEVEN_COLOR="$C_WARN"
  else SEVEN_COLOR="$C_GOOD"
  fi
  echo "---"
  echo "  7d  $(make_bar "$SEVEN_PCT") | font=Menlo size=12 color=$SEVEN_COLOR,$SEVEN_COLOR"
  if [ -n "$SEVEN_TIME_PCT" ]; then
    SEVEN_TIME_INT=$(python3 -c "print(int(float('$SEVEN_TIME_PCT')))" 2>/dev/null)
    if   [ "${SEVEN_TIME_INT:-0}" -ge 90 ] 2>/dev/null; then SEVEN_TIME_COLOR="$C_BAD"
    elif [ "${SEVEN_TIME_INT:-0}" -ge 75 ] 2>/dev/null; then SEVEN_TIME_COLOR="$C_WARN"
    else SEVEN_TIME_COLOR="$C_TIME"
    fi
    echo "  ⏱   $(make_bar "$SEVEN_TIME_PCT") | font=Menlo size=12 color=$SEVEN_TIME_COLOR,$SEVEN_TIME_COLOR"
  fi
  echo "  Resets  $SEVEN_RESET_STR | font=Menlo size=11 color=$C_INFO,$C_INFO"
fi

echo "---"
UPDATED_AT=$(stat -f "%Sm" -t "%H:%M:%S" "$CACHE_FILE" 2>/dev/null || echo "—")
echo "  Updated $UPDATED_AT | font=Menlo size=11 color=$C_DIM,$C_DIM"
echo "Refresh | bash=$PLUGIN_PATH param1=--force terminal=false refresh=true font=Menlo size=11 color=$C_DIM,$C_DIM"
