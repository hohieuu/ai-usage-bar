#!/bin/bash
# Claude Code Usage Bar — SwiftBar Plugin
# Version: 1.3.0
# Uses GET /api/oauth/usage directly — no hook or /tmp files required.
# Updated: 2026-03-25
# Repo: https://github.com/hohieuu/ai-usage-bar
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>false</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>false</swiftbar.hideSwiftBar>
# <swiftbar.title>Claude Usage</swiftbar.title>

# ── Detect light/dark mode and set colors ──────────────────────────────────
LIGHT_GOOD="#005e00";   DARK_GOOD="#00cc44"
LIGHT_WARN="#dd5500";   DARK_WARN="#ffaa00"
LIGHT_BAD="#dd0000";    DARK_BAD="#ff4444"
LIGHT_DIM="#333333";    DARK_DIM="#aaaaaa"
LIGHT_INFO="#0055dd";   DARK_INFO="#6699ff"
LIGHT_TIME="#0099dd";   DARK_TIME="#44aaff"

C_GOOD="$LIGHT_GOOD,$DARK_GOOD"
C_WARN="$LIGHT_WARN,$DARK_WARN"
C_BAD="$LIGHT_BAD,$DARK_BAD"
C_DIM="$LIGHT_DIM,$DARK_DIM"
C_INFO="$LIGHT_INFO,$DARK_INFO"
C_TIME="$LIGHT_TIME,$DARK_TIME"

# ── Cache paths ────────────────────────────────────────────────────────────
CACHE_DIR="$HOME/.claude-usage-bar"
CACHE_FILE="$CACHE_DIR/cache.json"
RETRY_FILE="$CACHE_DIR/retry_after"
STALE_FILE="$CACHE_DIR/stale_count"
ERR429_FILE="$CACHE_DIR/err429_count"
HEADERS_TMP="/tmp/claude-usage-api-headers.tmp"
PLUGIN_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$PLUGIN_PATH")" && pwd)"
mkdir -p "$CACHE_DIR"

# ── Force-refresh flag (set by Refresh button) ─────────────────────────────
FORCE_REFRESH=0
if [ "${1:-}" = "--force" ]; then
  FORCE_REFRESH=1
  rm -f "$RETRY_FILE"
elif [ "${1:-}" = "--update" ]; then
  echo "Updating Claude Usage Bar..."
  curl -fsSL https://raw.githubusercontent.com/hohieuu/ai-usage-bar/main/install/install.sh | bash
  exit 0
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
  if [ "$FORCE_REFRESH" = "0" ] && [ "$CACHE_AGE" -lt 180 ] 2>/dev/null; then
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
    rm -f "$RETRY_FILE" "$STALE_FILE" "$ERR429_FILE"
    echo "$RESPONSE"
    return 0
  elif [ "$HTTP_CODE" = "429" ]; then
    RETRY_SECS=$(grep -i "^retry-after:" "$HEADERS_TMP" 2>/dev/null | awk '{print $2}' | tr -d '\r')
    if [ -n "$RETRY_SECS" ]; then
      echo $(( $(date +%s) + RETRY_SECS )) > "$RETRY_FILE"
    fi
    _C=$(cat "$ERR429_FILE" 2>/dev/null || echo 0)
    echo $(( _C + 1 )) > "$ERR429_FILE"
  fi
  return 1
}

# ── Load data: try API first, fall back to cache ───────────────────────────
API_DATA=$(fetch_usage 2>/dev/null)
if [ -z "$API_DATA" ] && [ -f "$CACHE_FILE" ]; then
  API_DATA=$(cat "$CACHE_FILE" 2>/dev/null)
  USING_CACHE=1
  STALE_COUNT=$(cat "$STALE_FILE" 2>/dev/null || echo 0)
  STALE_COUNT=$(( STALE_COUNT + 1 ))
  echo "$STALE_COUNT" > "$STALE_FILE"
else
  STALE_COUNT=0
fi

# Debug: remaining retry-after time if in backoff
RETRY_REMAINING=""
if [ -f "$RETRY_FILE" ]; then
  RETRY_TS=$(cat "$RETRY_FILE" 2>/dev/null)
  NOW=$(date +%s)
  if [ -n "$RETRY_TS" ] && [ "$NOW" -lt "$RETRY_TS" ] 2>/dev/null; then
    SECS_LEFT=$(( RETRY_TS - NOW ))
    MINS_LEFT=$(( SECS_LEFT / 60 ))
    RETRY_REMAINING="${MINS_LEFT}m"
  fi
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
  if   [ "${FIVE_INT:-0}" -ge 100 ] 2>/dev/null; then BAR_COLOR="#5500cc,#9966ff"; LABEL="Claude🧘100%"; LABEL_COLOR="#5500cc,#9966ff"; LABEL_COLOR_DARK="#9966ff"
  elif [ "${FIVE_INT:-0}" -ge 80 ] 2>/dev/null; then BAR_COLOR="$C_BAD"; LABEL="Claude ${FIVE_INT}%"; LABEL_COLOR="$C_BAD"; LABEL_COLOR_DARK="$DARK_BAD"
  elif [ "${FIVE_INT:-0}" -ge 50 ] 2>/dev/null; then BAR_COLOR="$C_WARN"; LABEL="Claude ${FIVE_INT}%"; LABEL_COLOR="$C_WARN"; LABEL_COLOR_DARK="$DARK_WARN"
  else BAR_COLOR="$C_GOOD"; LABEL="Claude ${FIVE_INT}%"; LABEL_COLOR="$C_GOOD"; LABEL_COLOR_DARK="$DARK_GOOD"
  fi
  if [ "${USING_CACHE:-0}" = "1" ]; then
    if [ "${STALE_COUNT:-0}" -ge 5 ] 2>/dev/null; then
      LABEL="${LABEL} · err ${STALE_COUNT}t"
    else
      LABEL="${LABEL} ·"
    fi
  fi
else
  FIVE_INT=0; BAR_COLOR="$C_DIM"; LABEL="Claude --"; LABEL_COLOR="$C_DIM"; LABEL_COLOR_DARK="$DARK_DIM"
fi

if [ -n "$SEVEN_PCT" ]; then
  SEVEN_INT=$(python3 -c "print(int(float('$SEVEN_PCT')))" 2>/dev/null)
else
  SEVEN_INT=0
fi

# ── Progress bar helper (10 chars) ────────────────────────────────────────
make_bar() {
  python3 -c "
p = min(max(int(float('${1:-0}')), 0), 100)
filled = round(p / 10)
print('█' * filled + '░' * (10 - filled) + f' {p}%')
" 2>/dev/null
}

# ── Fun message helper (reads messages.json) ────────────────────────────
get_message() {
  local key="$1" usage="$2" time_pct="$3" u_7d="${4:-0}"
  local msg_file="$SCRIPT_DIR/messages.json"
  [ -z "$usage" ] || [ -z "$time_pct" ] && return
  [ ! -f "$msg_file" ] && return
  python3 -c "
import json, sys
try:
    with open('$msg_file') as f:
        rules = json.load(f).get('$key', [])
    u, t, u_7d = float('$usage'), float('$time_pct'), float('$u_7d')
    ns = {'u': u, 't': t, 'u_7d': u_7d, 'abs': abs, 'true': True, 'false': False, '__builtins__': {}}
    for r in rules:
        if eval(r['when'], ns):
            if r.get('msg'):
                print(r['msg'] + '\n' + r.get('color', '#aaaaaa'))
            break
except: pass
" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════
# OUTPUT
# ══════════════════════════════════════════════════════════════════════════
echo "$LABEL | font=Menlo-Bold size=13 color=${LABEL_COLOR_DARK:-$DARK_DIM}"
echo "---"

# ── Header — clickable row: title + updated time + refresh action ───────────
UPDATED_AT=$(stat -f "%Sm" -t "%H:%M:%S" "$CACHE_FILE" 2>/dev/null || echo "—")
ERR429_COUNT=$(cat "$ERR429_FILE" 2>/dev/null || echo 0)
PLUGIN_PATH_FULL="$(cd "$(dirname "$PLUGIN_PATH")" && pwd)/$(basename "$PLUGIN_PATH")"

if [ "${ERR429_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  HDR_LABEL="Claude Usage  ·  ${UPDATED_AT}  (429×${ERR429_COUNT})  [click to refresh]"
  HDR_COLOR="$C_WARN"
elif [ "${USING_CACHE:-0}" = "1" ]; then
  HDR_LABEL="Claude Usage  ·  ${UPDATED_AT}  [click to refresh]"
  HDR_COLOR="$C_DIM"
else
  HDR_LABEL="Claude Usage  ·  ${UPDATED_AT}  [click to refresh]"
  HDR_COLOR="$BAR_COLOR"
fi
echo "$HDR_LABEL | font=Menlo-Bold size=12 color=$HDR_COLOR bash=$PLUGIN_PATH_FULL param1=--force terminal=false refresh=true"

# ── 5h window ──────────────────────────────────────────────────────────────
if [ -n "$FIVE_PCT" ] && [ -n "$FIVE_RESETS" ]; then
  echo "  5h  $(make_bar "$FIVE_PCT") | font=Menlo size=12 color=$BAR_COLOR refresh=true"
  if [ -n "$FIVE_TIME_PCT" ]; then
    FIVE_TIME_INT=$(python3 -c "print(int(float('$FIVE_TIME_PCT')))" 2>/dev/null)
    if   [ "${FIVE_TIME_INT:-0}" -ge 90 ] 2>/dev/null; then TIME_COLOR="$C_BAD"
    elif [ "${FIVE_TIME_INT:-0}" -ge 75 ] 2>/dev/null; then TIME_COLOR="$C_WARN"
    else TIME_COLOR="$C_TIME"
    fi
    echo "  ⏱   $(make_bar "$FIVE_TIME_PCT") | font=Menlo size=12 color=$TIME_COLOR refresh=true"
  fi
  echo "  Resets  $FIVE_RESET_STR | font=Menlo size=11 color=$C_DIM refresh=true"
  FIVE_MSG_RAW=$(get_message "5h" "${FIVE_INT:-0}" "${FIVE_TIME_INT:-0}" "${SEVEN_INT:-0}")
  if [ -n "$FIVE_MSG_RAW" ]; then
    FIVE_MSG=$(echo "$FIVE_MSG_RAW" | head -1)
    FIVE_MSG_COLOR=$(echo "$FIVE_MSG_RAW" | tail -1)
    echo "  $FIVE_MSG | font=Menlo size=11 color=$FIVE_MSG_COLOR refresh=true"
  fi
elif [ -z "$TOKEN" ]; then
  echo "  Not logged in to Claude Code | font=Menlo size=12 color=$C_BAD refresh=true"
  echo "  Run: claude login | font=Menlo size=11 color=$C_DIM refresh=true"
else
  echo "  Fetching usage... | font=Menlo size=12 color=$C_DIM refresh=true"
fi

# ── 7d window ──────────────────────────────────────────────────────────────
if [ -n "$SEVEN_PCT" ]; then
  if   [ "${SEVEN_INT:-0}" -ge 80 ] 2>/dev/null; then SEVEN_COLOR="$C_BAD"
  elif [ "${SEVEN_INT:-0}" -ge 50 ] 2>/dev/null; then SEVEN_COLOR="$C_WARN"
  else SEVEN_COLOR="$C_GOOD"
  fi
  echo "---"
  echo "  7d  $(make_bar "$SEVEN_PCT") | font=Menlo size=12 color=$SEVEN_COLOR refresh=true"
  if [ -n "$SEVEN_TIME_PCT" ]; then
    SEVEN_TIME_INT=$(python3 -c "print(int(float('$SEVEN_TIME_PCT')))" 2>/dev/null)
    if   [ "${SEVEN_TIME_INT:-0}" -ge 90 ] 2>/dev/null; then SEVEN_TIME_COLOR="$C_BAD"
    elif [ "${SEVEN_TIME_INT:-0}" -ge 75 ] 2>/dev/null; then SEVEN_TIME_COLOR="$C_WARN"
    else SEVEN_TIME_COLOR="$C_TIME"
    fi
    echo "  ⏱   $(make_bar "$SEVEN_TIME_PCT") | font=Menlo size=12 color=$SEVEN_TIME_COLOR refresh=true"
  fi
  echo "  Resets  $SEVEN_RESET_STR | font=Menlo size=11 color=$C_DIM refresh=true"
  
  REMAINING_U=$((100 - SEVEN_INT))
  REMAINING_D=$(python3 -c "print(max(int((100 - float('$SEVEN_TIME_INT')) / (100/7)), 1))" 2>/dev/null || echo "1")
  PACE_NEEDED=$(python3 -c "print(round((100 - float('$SEVEN_INT')) / max(float('$REMAINING_D'), 0.1), 1))" 2>/dev/null || echo "14.0")
  ACTUAL_RATE=$(python3 -c "print(round(float('$SEVEN_INT') / max(float('$SEVEN_TIME_INT') * 0.07, 0.1), 1))" 2>/dev/null || echo "14.0")
  
  SEVEN_MSG_RAW=$(get_message "7d_optimization" "${SEVEN_INT:-0}" "${SEVEN_TIME_INT:-0}")
  if [ -n "$SEVEN_MSG_RAW" ]; then
    SEVEN_MSG=$(echo "$SEVEN_MSG_RAW" | head -1)
    SEVEN_MSG_COLOR=$(echo "$SEVEN_MSG_RAW" | tail -1)
    SEVEN_MSG=${SEVEN_MSG//\{\{remaining_u\}\}/$REMAINING_U}
    SEVEN_MSG=${SEVEN_MSG//\{\{remaining_d\}\}/$REMAINING_D}
    SEVEN_MSG=${SEVEN_MSG//\{\{pace_needed\}\}/$PACE_NEEDED}
    SEVEN_MSG=${SEVEN_MSG//\{\{actual_rate\}\}/$ACTUAL_RATE}
    echo "  $SEVEN_MSG | font=Menlo size=11 color=$SEVEN_MSG_COLOR refresh=true"
  fi
fi

echo "---"
if [ -n "$RETRY_REMAINING" ]; then
  echo "  ⚠ Rate limited — retry in ${RETRY_REMAINING} | font=Menlo size=11 color=$C_WARN refresh=true"
fi
echo "Check for update | bash=$PLUGIN_PATH_FULL param1=--update terminal=true font=Menlo size=11"
