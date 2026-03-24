#!/bin/bash
# Claude Code Usage Bar — SwiftBar Plugin
# Repo: https://github.com/YOUR_USERNAME/claude-usage-bar
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>false</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>false</swiftbar.hideSwiftBar>
# <swiftbar.title>Claude Usage</swiftbar.title>

RTK_DB="$HOME/Library/Application Support/rtk/history.db"

# ── Theme: always dark ─────────────────────────────────────────────────────
C_GOOD="#00cc44";  C_WARN="#ffaa00";  C_BAD="#ff4444"
C_DIM="#aaaaaa";   C_INFO="#6699ff";  C_FG="#ffffff"
C_TIME="#44aaff"   # time-progress bar: calm blue

# ── Pick the most recent valid session status ──────────────────────────────
# Reads all /tmp/claude-status-*.json files, picks the one with the
# highest resets_at (= most recent 5h window) to avoid stale sessions
STATUS_FILE=$(python3 - <<'PYEOF' 2>/dev/null
import json, glob, os

best_file = None
best_resets = 0
best_pct = -1

for f in glob.glob('/tmp/claude-status-*.json'):
    try:
        d = json.load(open(f))
        five = d.get('rate_limits', {}).get('five_hour', {})
        resets = five.get('resets_at', 0)
        pct = float(five.get('used_percentage') or -1)
        if resets and (resets > best_resets or (resets == best_resets and pct > best_pct)):
            best_resets = resets
            best_pct = pct
            best_file = f
    except:
        pass

if best_file:
    print(best_file)
PYEOF
)

# ── Parse status data ──────────────────────────────────────────────────────
_TMP_VARS=$(mktemp)
if [ -n "$STATUS_FILE" ] && [ -f "$STATUS_FILE" ]; then
  python3 - "$STATUS_FILE" > "$_TMP_VARS" 2>/dev/null << 'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    rl   = d.get('rate_limits', {})
    five = rl.get('five_hour', {})
    week = rl.get('seven_day', {})
    ctx  = d.get('context_window', {})
    cost = d.get('cost', {})
    def e(v): return str(v) if v not in ('', None) else ''
    model = d.get('model', {})
    print("MODEL_NAME='" + e(model.get('display_name')) + "'")
    print("FIVE_PCT="   + e(five.get('used_percentage')))
    print("FIVE_RESETS="+ e(five.get('resets_at')))
    print("SEVEN_PCT="  + e(week.get('used_percentage')))
    print("SEVEN_RESETS="+ e(week.get('resets_at')))
    print("CTX_PCT="    + e(ctx.get('used_percentage')))
    print("TOTAL_COST=" + e(cost.get('total_cost_usd')))
except: pass
PYEOF
  source "$_TMP_VARS"
fi
rm -f "$_TMP_VARS"

# ── Format reset countdowns ────────────────────────────────────────────────
fmt_reset() {
  local epoch="$1" days="$2"
  [ -z "$epoch" ] && echo "?" && return
  python3 -c "
from datetime import datetime, timezone
ts = int(float('$epoch'))
dt = datetime.fromtimestamp(ts, tz=timezone.utc).astimezone()
now = datetime.now(timezone.utc)
secs = max(ts - int(now.timestamp()), 0)
h,r = divmod(secs, 3600); m = r//60
if $days and h >= 24:
    d = h//24; h = h%24
    print(f'{d}d {h}h  ·  {dt.strftime(\"%a %H:%M\")}')
else:
    print(f'{h}h {m}m  ·  {dt.strftime(\"%H:%M\")}')
" 2>/dev/null || echo "?"
}

FIVE_RESET_STR=$(fmt_reset "$FIVE_RESETS" 0)
SEVEN_RESET_STR=$(fmt_reset "$SEVEN_RESETS" 1)

# ── Compute 5h time-window progress ────────────────────────────────────────
FIVE_TIME_PCT=""
if [ -n "$FIVE_RESETS" ]; then
  FIVE_TIME_PCT=$(python3 -c "
from datetime import datetime, timezone
now = datetime.now(timezone.utc).timestamp()
resets = float('$FIVE_RESETS')
start  = resets - 5 * 3600
elapsed = max(now - start, 0)
pct = min(elapsed / (5 * 3600) * 100, 100)
print(f'{pct:.1f}')
" 2>/dev/null)
fi

SEVEN_TIME_PCT=""
if [ -n "$SEVEN_RESETS" ]; then
  SEVEN_TIME_PCT=$(python3 -c "
from datetime import datetime, timezone
now = datetime.now(timezone.utc).timestamp()
resets = float('$SEVEN_RESETS')
start  = resets - 7 * 24 * 3600
elapsed = max(now - start, 0)
pct = min(elapsed / (7 * 24 * 3600) * 100, 100)
print(f'{pct:.1f}')
" 2>/dev/null)
fi

# ── RTK today's savings ────────────────────────────────────────────────────
TODAY=$(date +%Y-%m-%d)
if [ -f "$RTK_DB" ] && command -v sqlite3 &>/dev/null; then
  _row=$(sqlite3 "$RTK_DB" \
    "SELECT COUNT(*),COALESCE(SUM(saved_tokens),0),COALESCE(SUM(input_tokens),0)
     FROM commands WHERE substr(timestamp,1,10)='$TODAY';" 2>/dev/null)
  IFS='|' read -r RTK_CMDS RTK_SAVED RTK_IN <<< "$_row"
  if [ "${RTK_IN:-0}" -gt 0 ] 2>/dev/null; then
    RTK_PCT=$(python3 -c "print(f'{${RTK_SAVED:-0}/(${RTK_SAVED:-0}+${RTK_IN:-0})*100:.0f}')" 2>/dev/null)
  else
    RTK_PCT=0
  fi
else
  RTK_CMDS=0; RTK_SAVED=0; RTK_PCT=0
fi

# ── Pick bar color based on usage ─────────────────────────────────────────
if [ -n "$FIVE_PCT" ]; then
  FIVE_INT=$(python3 -c "print(int(float('$FIVE_PCT')))" 2>/dev/null)
  if   [ "${FIVE_INT:-0}" -ge 80 ] 2>/dev/null; then BAR_COLOR="$C_BAD"
  elif [ "${FIVE_INT:-0}" -ge 50 ] 2>/dev/null; then BAR_COLOR="$C_WARN"
  else BAR_COLOR="$C_GOOD"
  fi

  MODEL_LABEL="${MODEL_NAME:-Claude}"
  LABEL="${MODEL_LABEL} - ${FIVE_INT}%"
else
  FIVE_INT=0; BAR_COLOR="$C_DIM"; LABEL="${MODEL_NAME:-CC} --"
fi

# ── Progress bar helper (10 chars) ────────────────────────────────────────
make_bar() {
  local pct="${1:-0}"
  python3 -c "
p = min(max(int(float('$pct')), 0), 100)
filled = round(p / 10)
print('█' * filled + '░' * (10 - filled) + f' {p}%')
" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════
# OUTPUT
# ══════════════════════════════════════════════════════════════════════════
echo "$LABEL | font=Menlo-Bold size=13 color=$BAR_COLOR"
echo "---"

# ── Claude rate limits ─────────────────────────────────────────────────────
echo "Claude Usage | font=Menlo-Bold size=12 color=$BAR_COLOR,$BAR_COLOR"
if [ -n "$FIVE_PCT" ] && [ -n "$FIVE_RESETS" ]; then
  echo "  5h  $(make_bar "$FIVE_PCT") | font=Menlo size=12 color=$BAR_COLOR,$BAR_COLOR"
  if [ -n "$FIVE_TIME_PCT" ]; then
    FIVE_TIME_INT=$(python3 -c "print(int(float('$FIVE_TIME_PCT')))" 2>/dev/null)
    # Time color: blue when early, orange when >75%, red when >90%
    if   [ "${FIVE_TIME_INT:-0}" -ge 90 ] 2>/dev/null; then TIME_COLOR="$C_BAD"
    elif [ "${FIVE_TIME_INT:-0}" -ge 75 ] 2>/dev/null; then TIME_COLOR="$C_WARN"
    else TIME_COLOR="$C_TIME"
    fi
    echo "  ⏱   $(make_bar "$FIVE_TIME_PCT") | font=Menlo size=12 color=$TIME_COLOR,$TIME_COLOR"
  fi
  echo "  Resets  $FIVE_RESET_STR | font=Menlo size=11 color=$C_INFO,$C_INFO"
else
  echo "  Waiting for first Claude response... | font=Menlo size=12 color=$C_DIM,$C_DIM"
fi

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

if [ -n "$CTX_PCT" ]; then
  CTX_INT=$(python3 -c "print(int(float('$CTX_PCT')))" 2>/dev/null)
  echo "---"
  echo "  Ctx $(make_bar "$CTX_PCT") | font=Menlo size=12 color=$C_DIM,$C_DIM"
fi

echo "---"

# ── RTK savings ────────────────────────────────────────────────────────────
echo "RTK Today | font=Menlo-Bold size=12 color=$C_WARN,$C_WARN"
echo "  Cmds   $RTK_CMDS | font=Menlo size=12 color=$C_WARN,$C_WARN"
echo "  Saved  $RTK_SAVED tokens ($RTK_PCT%) | font=Menlo size=12 color=$C_WARN,$C_WARN"
echo "---"
echo "Refresh | refresh=true font=Menlo size=11 color=$C_DIM,$C_DIM"
