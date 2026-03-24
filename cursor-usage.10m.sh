#!/bin/bash
# Cursor Usage Bar — SwiftBar Plugin (10m refresh)
# Repo: https://github.com/hohieuu/claude-usage-bar
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>false</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>false</swiftbar.hideSwiftBar>
# <swiftbar.title>Cursor Usage</swiftbar.title>

CURSOR_DB="$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
CACHE_DIR="$HOME/.cursor-usage-bar"
CACHE_FILE="$CACHE_DIR/cache.json"
CACHE_MAX_AGE=600  # 10 minutes

# ── Theme: always dark ─────────────────────────────────────────────────────
C_GOOD="#00cc44";  C_WARN="#ffaa00";  C_BAD="#ff4444"
C_DIM="#aaaaaa";   C_INFO="#6699ff";  C_FG="#ffffff"
C_TIME="#44aaff";  C_ACCENT="#cc66ff"

# ── Auto-extract Bearer token from Cursor's local DB ─────────────────────
if [ ! -f "$CURSOR_DB" ]; then
  echo "⌘ No Cursor | font=Menlo-Bold size=13 color=$C_DIM"
  echo "---"
  echo "Cursor not installed | font=Menlo size=12 color=$C_DIM,$C_DIM"
  exit 0
fi

ACCESS_TOKEN=$(sqlite3 "$CURSOR_DB" \
  "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';" 2>/dev/null || true)

if [ -z "$ACCESS_TOKEN" ]; then
  echo "⌘ No Auth | font=Menlo-Bold size=13 color=$C_BAD"
  echo "---"
  echo "Not logged in to Cursor | font=Menlo size=12 color=$C_DIM,$C_DIM"
  exit 0
fi

# ── Fetch or use cache ─────────────────────────────────────────────────────
mkdir -p "$CACHE_DIR"
NEED_FETCH=1
if [ -f "$CACHE_FILE" ]; then
  CACHE_AGE=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0) ))
  [ "$CACHE_AGE" -lt "$CACHE_MAX_AGE" ] && NEED_FETCH=0
fi

if [ "$NEED_FETCH" -eq 1 ]; then
  HTTP_RESP=$(curl -s -w "\n%{http_code}" --max-time 10 \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "https://api2.cursor.sh/auth/usage" 2>/dev/null || true)

  HTTP_CODE=$(echo "$HTTP_RESP" | tail -1)
  HTTP_BODY=$(echo "$HTTP_RESP" | sed '$d')

  if [ "$HTTP_CODE" = "200" ] && [ -n "$HTTP_BODY" ]; then
    echo "$HTTP_BODY" > "$CACHE_FILE"
  elif [ ! -f "$CACHE_FILE" ]; then
    echo "⌘ Error | font=Menlo-Bold size=13 color=$C_BAD"
    echo "---"
    if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
      echo "Token expired. Restart Cursor. | font=Menlo size=12 color=$C_BAD,$C_BAD"
    else
      echo "API error ($HTTP_CODE) | font=Menlo size=12 color=$C_BAD,$C_BAD"
    fi
    echo "---"
    echo "Refresh | refresh=true font=Menlo size=11 color=$C_DIM,$C_DIM"
    exit 0
  fi
fi

# ── Parse usage data ──────────────────────────────────────────────────────
_TMP_VARS=$(mktemp)
python3 - "$CACHE_FILE" > "$_TMP_VARS" 2>/dev/null << 'PYEOF'
import json, sys
from datetime import datetime, timezone

try:
    d = json.load(open(sys.argv[1]))

    # Count requests per model; detect limit from maxRequestUsage
    total_requests = 0
    monthly_limit = 0
    models = []
    for key, val in d.items():
        if isinstance(val, dict) and 'numRequests' in val:
            n = val['numRequests']
            total_requests += n
            if n > 0:
                models.append((key, n))
            # Pick the highest maxRequestUsage as the plan limit
            mx = val.get('maxRequestUsage')
            if mx and mx > monthly_limit:
                monthly_limit = mx

    if monthly_limit == 0:
        monthly_limit = 500  # fallback

    models.sort(key=lambda x: -x[1])

    # Billing cycle
    start_str = d.get('startOfMonth', '')
    if start_str:
        start_dt = datetime.fromisoformat(start_str.replace('Z', '+00:00'))
    else:
        now = datetime.now(timezone.utc)
        start_dt = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

    if start_dt.month == 12:
        end_dt = start_dt.replace(year=start_dt.year + 1, month=1)
    else:
        end_dt = start_dt.replace(month=start_dt.month + 1)

    now = datetime.now(timezone.utc)
    total_days = (end_dt - start_dt).days
    elapsed_days = max((now - start_dt).days, 1)
    remaining_days = max((end_dt - now).days, 0)

    pct = min(total_requests / monthly_limit * 100, 100) if monthly_limit > 0 else 0

    daily_avg = total_requests / elapsed_days if elapsed_days > 0 else 0
    projected = int(daily_avg * total_days)
    remaining_requests = max(monthly_limit - total_requests, 0)
    daily_budget = remaining_requests / remaining_days if remaining_days > 0 else 0

    time_pct = min(elapsed_days / total_days * 100, 100) if total_days > 0 else 0

    print(f"TOTAL_REQ={total_requests}")
    print(f"MONTHLY_LIMIT={monthly_limit}")
    print(f"USAGE_PCT={pct:.1f}")
    print(f"CYCLE_START='{start_dt.strftime('%b %d')}'")
    print(f"CYCLE_END='{end_dt.strftime('%b %d')}'")
    print(f"ELAPSED_DAYS={elapsed_days}")
    print(f"TOTAL_DAYS={total_days}")
    print(f"REMAINING_DAYS={remaining_days}")
    print(f"TIME_PCT={time_pct:.1f}")
    print(f"DAILY_AVG={daily_avg:.1f}")
    print(f"PROJECTED={projected}")
    print(f"DAILY_BUDGET={daily_budget:.1f}")
    print(f"REMAINING_REQ={remaining_requests}")


except Exception as e:
    print(f"PARSE_ERROR='{e}'")
PYEOF

source "$_TMP_VARS"
rm -f "$_TMP_VARS"

# ── Handle parse error ──────────────────────────────────────────────────
if [ -n "${PARSE_ERROR:-}" ]; then
  echo "⌘ Error | font=Menlo-Bold size=13 color=$C_BAD"
  echo "---"
  echo "Parse error: $PARSE_ERROR | font=Menlo size=12 color=$C_DIM,$C_DIM"
  echo "---"
  echo "Refresh | refresh=true font=Menlo size=11 color=$C_DIM,$C_DIM"
  exit 0
fi

# ── Pick bar color based on usage ─────────────────────────────────────────
USAGE_INT=$(python3 -c "print(int(float('${USAGE_PCT:-0}')))" 2>/dev/null)
PROJ_PCT=0
if [ "${MONTHLY_LIMIT:-500}" -gt 0 ] 2>/dev/null; then
  PROJ_PCT=$(python3 -c "print(int(float('${PROJECTED:-0}') / float('${MONTHLY_LIMIT:-500}') * 100))" 2>/dev/null)
fi

if   [ "${USAGE_INT:-0}" -ge 90 ] 2>/dev/null; then BAR_COLOR="$C_BAD"
elif [ "${USAGE_INT:-0}" -ge 70 ] 2>/dev/null; then BAR_COLOR="$C_WARN"
elif [ "${PROJ_PCT:-0}" -ge 100 ] 2>/dev/null; then BAR_COLOR="$C_WARN"
else BAR_COLOR="$C_GOOD"
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

# ── Menu bar label ────────────────────────────────────────────────────────
echo "⌘ ${TOTAL_REQ:-0}/${MONTHLY_LIMIT} | font=Menlo-Bold size=13 color=$BAR_COLOR"
echo "---"

# ── Monthly usage ─────────────────────────────────────────────────────────
echo "Cursor Usage | font=Menlo-Bold size=12 color=$C_ACCENT,$C_ACCENT"
echo "  Month $(make_bar "$USAGE_PCT") | font=Menlo size=12 color=$BAR_COLOR,$BAR_COLOR"
echo "  ${TOTAL_REQ:-0} / ${MONTHLY_LIMIT} premium requests | font=Menlo size=11 color=$C_FG,$C_FG"

echo "---"

# ── Billing cycle ─────────────────────────────────────────────────────────
echo "Billing Cycle | font=Menlo-Bold size=12 color=$C_INFO,$C_INFO"
echo "  ${CYCLE_START:-?} → ${CYCLE_END:-?} | font=Menlo size=11 color=$C_FG,$C_FG"

if [ -n "${TIME_PCT:-}" ]; then
  TIME_INT=$(python3 -c "print(int(float('${TIME_PCT:-0}')))" 2>/dev/null)
  if   [ "${TIME_INT:-0}" -ge 90 ] 2>/dev/null; then TIME_COLOR="$C_BAD"
  elif [ "${TIME_INT:-0}" -ge 75 ] 2>/dev/null; then TIME_COLOR="$C_WARN"
  else TIME_COLOR="$C_TIME"
  fi
  echo "  ⏱   $(make_bar "$TIME_PCT") | font=Menlo size=12 color=$TIME_COLOR,$TIME_COLOR"
  echo "  Day ${ELAPSED_DAYS:-?} of ${TOTAL_DAYS:-?} · ${REMAINING_DAYS:-?}d left | font=Menlo size=11 color=$C_INFO,$C_INFO"
fi

echo "---"

# ── Pace & projection ────────────────────────────────────────────────────
echo "Pace | font=Menlo-Bold size=12 color=$C_FG,$C_FG"

echo "  Avg    ${DAILY_AVG:-0} req/day | font=Menlo size=11 color=$C_FG,$C_FG"

BUDGET_COLOR="$C_GOOD"
if [ -n "${DAILY_AVG:-}" ] && [ -n "${DAILY_BUDGET:-}" ]; then
  OVER=$(python3 -c "print('1' if float('${DAILY_AVG}') > float('${DAILY_BUDGET}') * 1.1 else '0')" 2>/dev/null)
  [ "$OVER" = "1" ] && BUDGET_COLOR="$C_WARN"
fi
echo "  Budget ${DAILY_BUDGET:-0} req/day | font=Menlo size=11 color=$BUDGET_COLOR,$BUDGET_COLOR"

PROJ_COLOR="$C_GOOD"
if   [ "${PROJ_PCT:-0}" -ge 100 ] 2>/dev/null; then PROJ_COLOR="$C_BAD"
elif [ "${PROJ_PCT:-0}" -ge 85 ]  2>/dev/null; then PROJ_COLOR="$C_WARN"
fi
echo "  Proj.  ~${PROJECTED:-0} at month end | font=Menlo size=11 color=$PROJ_COLOR,$PROJ_COLOR"

if [ "${PROJ_PCT:-0}" -ge 110 ] 2>/dev/null; then
  echo "  ⚠ On track to EXCEED limit | font=Menlo-Bold size=11 color=$C_BAD,$C_BAD"
elif [ "${PROJ_PCT:-0}" -ge 90 ] 2>/dev/null; then
  echo "  ⚠ Close to limit | font=Menlo size=11 color=$C_WARN,$C_WARN"
elif [ "${USAGE_INT:-0}" -ge 90 ] 2>/dev/null; then
  echo "  ✗ Almost exhausted | font=Menlo-Bold size=11 color=$C_BAD,$C_BAD"
else
  echo "  ✓ On track | font=Menlo size=11 color=$C_GOOD,$C_GOOD"
fi

echo "---"

# ── Footer ────────────────────────────────────────────────────────────────
if [ -f "$CACHE_FILE" ]; then
  CACHE_AGE=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0) ))
  if [ "$CACHE_AGE" -ge 60 ]; then
    AGE_STR="$((CACHE_AGE / 60))m ago"
  else
    AGE_STR="${CACHE_AGE}s ago"
  fi
  echo "Updated $AGE_STR | font=Menlo size=10 color=$C_DIM,$C_DIM"
fi
echo "Refresh (fetch latest) | bash='rm -f $HOME/.cursor-usage-bar/cache.json' refresh=true terminal=false font=Menlo size=11 color=$C_DIM,$C_DIM"
