#!/bin/bash
# Claude Code Usage Bar — SwiftBar Plugin
# Version: 1.4.0
# Uses GET /api/oauth/usage directly — no hook or /tmp files required.
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
PLUGIN_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$PLUGIN_PATH")" && pwd)"
mkdir -p "$CACHE_DIR"

# messages.json lives in the user data dir (alongside cache.json), NOT the
# SwiftBar plugin dir — keeps the plugin dir to a single file and avoids any
# "invalid plugin" cosmetic from SwiftBar scanning a non-plugin JSON.
# Fallback to legacy SCRIPT_DIR location for upgrades-in-progress.
MSG_FILE="$CACHE_DIR/messages.json"
[ ! -f "$MSG_FILE" ] && [ -f "$SCRIPT_DIR/messages.json" ] && MSG_FILE="$SCRIPT_DIR/messages.json"

# Race-safe scratch files; cleaned on exit so concurrent invocations don't
# clobber each other's curl headers or sourced vars.
HEADERS_TMP=$(mktemp -t claude-usage-headers.XXXXXX 2>/dev/null) || HEADERS_TMP="/tmp/claude-usage-headers.$$.tmp"
VARS_TMP=$(mktemp -t claude-usage-vars.XXXXXX 2>/dev/null)        || VARS_TMP="/tmp/claude-usage-vars.$$.tmp"
trap 'rm -f "$HEADERS_TMP" "$VARS_TMP"' EXIT

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

# ── Cap-state precheck (used inside fetch_usage, before any API call) ──────
# Returns non-empty if any window is ≥100% and not yet reset. Same logic is
# duplicated inside the main compute block below for post-fetch UI state.
get_cap_state() {
  local json="$1"
  [ -z "$json" ] && return
  python3 - "$json" <<'PYEOF' 2>/dev/null
import json, sys, datetime
try:
    d = json.loads(sys.argv[1])
    now = datetime.datetime.now(datetime.timezone.utc)
    for key in ('five_hour', 'seven_day'):
        w = d.get(key) or {}
        u, r = w.get('utilization'), w.get('resets_at')
        if u is not None and float(u) >= 100 and r:
            dt = datetime.datetime.fromisoformat(r)
            if dt > now:
                print(key)
                break
except: pass
PYEOF
}

# ── Fetch from API (TTL guard, cap-aware skip, rate-limit handling) ────────
fetch_usage() {
  [ -z "$TOKEN" ] && return 1

  # Serve fresh cache without hitting the API. Prevents 429s from menu-hover
  # refreshes and idle polling. Force-refresh button bypasses this.
  if [ "$FORCE_REFRESH" = "0" ] && [ -f "$CACHE_FILE" ] && [ "$CACHE_AGE" -lt 180 ] 2>/dev/null; then
    cat "$CACHE_FILE"
    return 0
  fi

  # Cap-aware skip: if cache shows we're at 100% and reset is still in the
  # future, the API can't tell us anything new — and it will 429 us for
  # asking. Serve cache, no network call, no 429 accumulation.
  if [ "$FORCE_REFRESH" = "0" ] && [ -f "$CACHE_FILE" ]; then
    if [ -n "$(get_cap_state "$(cat "$CACHE_FILE" 2>/dev/null)")" ]; then
      # Cap is the real reason for any prior 429s — clear stale state so the
      # UI shows "paused" instead of a misleading 429 count.
      rm -f "$RETRY_FILE" "$ERR429_FILE"
      cat "$CACHE_FILE"
      return 0
    fi
  fi

  # Respect Retry-After if we were previously 429'd or backed off
  if [ -f "$RETRY_FILE" ]; then
    RETRY_TS=$(cat "$RETRY_FILE" 2>/dev/null)
    NOW=$(date +%s)
    if [ -n "$RETRY_TS" ] && [ "$NOW" -lt "$RETRY_TS" ] 2>/dev/null; then
      return 1  # Still in backoff — caller falls back to cache
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
    # Atomic cache write: temp on same filesystem, then rename. Prevents a
    # truncated cache if the script is killed mid-write.
    TMP_CACHE=$(mktemp "$CACHE_DIR/cache.json.XXXXXX") \
      && printf '%s' "$RESPONSE" > "$TMP_CACHE" \
      && mv "$TMP_CACHE" "$CACHE_FILE"
    rm -f "$RETRY_FILE" "$STALE_FILE" "$ERR429_FILE"
    echo "$RESPONSE"
    return 0
  elif [ "$HTTP_CODE" = "429" ]; then
    ERR_COUNT=$(cat "$ERR429_FILE" 2>/dev/null || echo 0)
    ERR_COUNT=$(( ERR_COUNT + 1 ))
    echo "$ERR_COUNT" > "$ERR429_FILE"
    RETRY_SECS=$(grep -i "^retry-after:" "$HEADERS_TMP" 2>/dev/null | awk '{print $2}' | tr -d '\r')
    if [ -z "$RETRY_SECS" ]; then
      # Exponential backoff when server doesn't tell us: 5m, 10m, 20m, ... capped at 6h
      RETRY_SECS=$(python3 -c "print(min(300 * (2 ** ($ERR_COUNT - 1)), 21600))" 2>/dev/null || echo 300)
    fi
    echo $(( $(date +%s) + RETRY_SECS )) > "$RETRY_FILE"
  else
    # 4xx (other than 429), 5xx, or network failure (empty HTTP_CODE).
    # Short cool-off so we don't hammer through outages or auth issues.
    echo $(( $(date +%s) + 180 )) > "$RETRY_FILE"
  fi
  return 1
}

# ── Load data: try API first, fall back to cache ───────────────────────────
API_DATA=$(fetch_usage 2>/dev/null)
if [ -z "$API_DATA" ] && [ -f "$CACHE_FILE" ]; then
  # STALE only fires when we couldn't reach fresh data (backoff, auth fail).
  # Cap-skip and TTL paths both succeed via fetch_usage so they don't count.
  API_DATA=$(cat "$CACHE_FILE" 2>/dev/null)
  USING_CACHE=1
  STALE_COUNT=$(cat "$STALE_FILE" 2>/dev/null || echo 0)
  STALE_COUNT=$(( STALE_COUNT + 1 ))
  echo "$STALE_COUNT" > "$STALE_FILE"
else
  STALE_COUNT=0
fi

# ── Compute everything from API_DATA in one Python call ────────────────────
# Replaces what used to be ~10 separate python invocations. Outputs
# shell-quoted KEY=value lines (via shlex.quote) that we source below.
if [ -n "$API_DATA" ]; then
  python3 - "$API_DATA" "$MSG_FILE" > "$VARS_TMP" 2>/dev/null <<'PYEOF'
import json, sys, shlex, datetime

api_data = sys.argv[1]
msg_file = sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc)

def emit(k, v):
    print(f"{k}={shlex.quote('' if v is None else str(v))}")

def make_bar(pct):
    try: p = min(max(int(float(pct)), 0), 100)
    except: p = 0
    filled = round(p / 10)
    return '█' * filled + '░' * (10 - filled) + f' {p}%'

def fmt_reset(iso, allow_days):
    if not iso: return ""
    try:
        dt = datetime.datetime.fromisoformat(iso)
        secs = max(int((dt - now).total_seconds()), 0)
        h, r = divmod(secs, 3600); m = r // 60
        local = dt.astimezone()
        if allow_days and h >= 24:
            d = h // 24; h = h % 24
            return f"{d}d {h}h  ·  {local.strftime('%a %H:%M')}"
        return f"{h}h {m}m  ·  {local.strftime('%H:%M')}"
    except: return ""

def time_pct_of(iso, hrs):
    if not iso: return ""
    try:
        dt = datetime.datetime.fromisoformat(iso)
        start = dt.timestamp() - hrs * 3600
        elapsed = max(now.timestamp() - start, 0)
        return f"{min(elapsed / (hrs * 3600) * 100, 100):.1f}"
    except: return ""

def eval_msg(rules, key, u, t, u_7d):
    ns = {'u': float(u), 't': float(t), 'u_7d': float(u_7d),
          'abs': abs, 'true': True, 'false': False, '__builtins__': {}}
    for r in rules.get(key, []):
        try:
            if eval(r['when'], ns) and r.get('msg'):
                return r['msg'], r.get('color', '#aaaaaa')
        except: pass
    return "", ""

try:
    d = json.loads(api_data)
except:
    sys.exit(0)

try:
    with open(msg_file) as f: rules = json.load(f)
except:
    rules = {}

five = d.get('five_hour') or {}
week = d.get('seven_day') or {}

five_pct     = five.get('utilization')
five_resets  = five.get('resets_at')
seven_pct    = week.get('utilization')
seven_resets = week.get('resets_at')

five_int  = int(float(five_pct))  if five_pct  is not None else 0
seven_int = int(float(seven_pct)) if seven_pct is not None else 0
five_time_pct  = time_pct_of(five_resets, 5)
seven_time_pct = time_pct_of(seven_resets, 168)
five_time_int  = int(float(five_time_pct))  if five_time_pct  else 0
seven_time_int = int(float(seven_time_pct)) if seven_time_pct else 0

emit("FIVE_PCT",        five_pct  if five_pct  is not None else "")
emit("FIVE_RESETS",     five_resets or "")
emit("FIVE_INT",        five_int)
emit("FIVE_TIME_INT",   five_time_int)
emit("FIVE_RESET_STR",  fmt_reset(five_resets, False))
emit("FIVE_BAR",        make_bar(five_pct))
emit("FIVE_TIME_BAR",   make_bar(five_time_pct) if five_time_pct else "")

emit("SEVEN_PCT",       seven_pct if seven_pct is not None else "")
emit("SEVEN_RESETS",    seven_resets or "")
emit("SEVEN_INT",       seven_int)
emit("SEVEN_TIME_INT",  seven_time_int)
emit("SEVEN_RESET_STR", fmt_reset(seven_resets, True))
emit("SEVEN_BAR",       make_bar(seven_pct))
emit("SEVEN_TIME_BAR",  make_bar(seven_time_pct) if seven_time_pct else "")

# Messages — with 7d placeholders pre-substituted
fmsg, fcolor = eval_msg(rules, '5h', five_int, five_time_int, seven_int)
emit("FIVE_MSG",       fmsg)
emit("FIVE_MSG_COLOR", fcolor or "#aaaaaa")

smsg, scolor = eval_msg(rules, '7d_optimization', seven_int, seven_time_int, 0)
if smsg:
    remaining_u = 100 - seven_int
    remaining_d = max(int((100 - seven_time_int) / (100 / 7)), 1)
    pace_needed = round((100 - seven_int) / max(remaining_d, 0.1), 1)
    actual_rate = round(seven_int / max(seven_time_int * 0.07, 0.1), 1)
    smsg = (smsg.replace('{{remaining_u}}', str(remaining_u))
                .replace('{{remaining_d}}', str(remaining_d))
                .replace('{{pace_needed}}', str(pace_needed))
                .replace('{{actual_rate}}',  str(actual_rate)))
emit("SEVEN_MSG",       smsg)
emit("SEVEN_MSG_COLOR", scolor or "#aaaaaa")

# Cap state — soonest 100% window that hasn't reset yet
soonest, label = None, None
for key, w in (('five_hour', five), ('seven_day', week)):
    u, r = w.get('utilization'), w.get('resets_at')
    if u is not None and float(u) >= 100 and r:
        try:
            dt = datetime.datetime.fromisoformat(r)
            if dt > now and (soonest is None or dt < soonest):
                soonest, label = dt, key
        except: pass
if soonest:
    secs = int((soonest - now).total_seconds())
    h, rem = divmod(secs, 3600); m = rem // 60
    emit("CAP_WINDOW",    label)
    emit("CAP_REMAINING", f"{h}h {m}m")
    emit("CAP_LOCAL",     soonest.astimezone().strftime('%H:%M'))
else:
    emit("CAP_WINDOW", ""); emit("CAP_REMAINING", ""); emit("CAP_LOCAL", "")
PYEOF
  source "$VARS_TMP"
fi

# ── Derived state for output (cap label, retry countdown) ──────────────────
CAP_STATE=""
if [ -n "${CAP_WINDOW:-}" ]; then
  CAP_STATE="set"
  case "$CAP_WINDOW" in
    five_hour) CAP_LABEL="5h cap" ;;
    seven_day) CAP_LABEL="7d cap" ;;
    *)         CAP_LABEL="cap"   ;;
  esac
fi

RETRY_REMAINING=""
RETRY_LOCAL=""
if [ -f "$RETRY_FILE" ] && [ -z "$CAP_STATE" ]; then
  RETRY_TS=$(cat "$RETRY_FILE" 2>/dev/null)
  NOW=$(date +%s)
  if [ -n "$RETRY_TS" ] && [ "$NOW" -lt "$RETRY_TS" ] 2>/dev/null; then
    SECS_LEFT=$(( RETRY_TS - NOW ))
    MINS_LEFT=$(( SECS_LEFT / 60 ))
    if [ "$MINS_LEFT" -ge 60 ]; then
      RETRY_REMAINING="$(( MINS_LEFT / 60 ))h $(( MINS_LEFT % 60 ))m"
    else
      RETRY_REMAINING="${MINS_LEFT}m"
    fi
    RETRY_LOCAL=$(python3 -c "import sys,datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1])).strftime('%H:%M'))" "$RETRY_TS" 2>/dev/null)
  fi
fi

# ── Menu-bar label (color based on 5h utilization) ─────────────────────────
if [ -n "${FIVE_PCT:-}" ]; then
  if   [ "${FIVE_INT:-0}" -ge 100 ] 2>/dev/null; then BAR_COLOR="#5500cc,#9966ff"; LABEL="Claude🧘100%"; LABEL_COLOR_DARK="#9966ff"
  elif [ "${FIVE_INT:-0}" -ge 80 ] 2>/dev/null;  then BAR_COLOR="$C_BAD";          LABEL="Claude ${FIVE_INT}%"; LABEL_COLOR_DARK="$DARK_BAD"
  elif [ "${FIVE_INT:-0}" -ge 50 ] 2>/dev/null;  then BAR_COLOR="$C_WARN";         LABEL="Claude ${FIVE_INT}%"; LABEL_COLOR_DARK="$DARK_WARN"
  else                                                BAR_COLOR="$C_GOOD";         LABEL="Claude ${FIVE_INT}%"; LABEL_COLOR_DARK="$DARK_GOOD"
  fi
  # Stale-cache indicator: only when we couldn't reach fresh data (NOT for
  # cap-skip or TTL — those serve cache deliberately, not because of failure).
  if [ "${USING_CACHE:-0}" = "1" ]; then
    if [ "${STALE_COUNT:-0}" -ge 5 ] 2>/dev/null; then
      LABEL="${LABEL} · err ${STALE_COUNT}t"
    else
      LABEL="${LABEL} ·"
    fi
  fi
else
  BAR_COLOR="$C_DIM"; LABEL="Claude --"; LABEL_COLOR_DARK="$DARK_DIM"
fi

# ══════════════════════════════════════════════════════════════════════════
# OUTPUT
# ══════════════════════════════════════════════════════════════════════════
echo "$LABEL | font=Menlo-Bold size=13 color=${LABEL_COLOR_DARK:-$DARK_DIM}"
echo "---"

# ── Header — clickable row: title + state + refresh action ─────────────────
UPDATED_AT=$(stat -f "%Sm" -t "%H:%M:%S" "$CACHE_FILE" 2>/dev/null || echo "—")
ERR429_COUNT=$(cat "$ERR429_FILE" 2>/dev/null || echo 0)
PLUGIN_PATH_FULL="$(cd "$(dirname "$PLUGIN_PATH")" && pwd)/$(basename "$PLUGIN_PATH")"

if [ -n "$CAP_STATE" ]; then
  HDR_LABEL="Claude Usage  ·  🔒 paused (${CAP_LABEL} · resumes in ${CAP_REMAINING})  [click to force refresh]"
  HDR_COLOR="$C_INFO"
elif [ -n "$RETRY_REMAINING" ]; then
  HDR_LABEL="Claude Usage  ·  ⚠ backing off (retry in ${RETRY_REMAINING})  [click to force refresh]"
  HDR_COLOR="$C_WARN"
elif [ "${ERR429_COUNT:-0}" -gt 0 ] 2>/dev/null; then
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
if [ -n "${FIVE_PCT:-}" ]; then
  echo "  5h  $FIVE_BAR | font=Menlo size=12 color=$BAR_COLOR refresh=true"
  if [ -n "${FIVE_TIME_BAR:-}" ]; then
    if   [ "${FIVE_TIME_INT:-0}" -ge 90 ] 2>/dev/null; then TIME_COLOR="$C_BAD"
    elif [ "${FIVE_TIME_INT:-0}" -ge 75 ] 2>/dev/null; then TIME_COLOR="$C_WARN"
    else                                                    TIME_COLOR="$C_TIME"
    fi
    echo "  ⏱   $FIVE_TIME_BAR | font=Menlo size=12 color=$TIME_COLOR refresh=true"
  fi
  if [ -n "${FIVE_RESETS:-}" ]; then
    echo "  Resets  $FIVE_RESET_STR | font=Menlo size=11 color=$C_DIM refresh=true"
  else
    echo "  No active session  ·  awaiting first prompt | font=Menlo size=11 color=$C_DIM refresh=true"
  fi
  if [ -n "${FIVE_MSG:-}" ]; then
    echo "  $FIVE_MSG | font=Menlo size=11 color=$FIVE_MSG_COLOR refresh=true"
  fi
elif [ -z "$TOKEN" ]; then
  echo "  Not logged in to Claude Code | font=Menlo size=12 color=$C_BAD refresh=true"
  echo "  Run: claude login | font=Menlo size=11 color=$C_DIM refresh=true"
else
  echo "  Fetching usage... | font=Menlo size=12 color=$C_DIM refresh=true"
fi

# ── 7d window ──────────────────────────────────────────────────────────────
if [ -n "${SEVEN_PCT:-}" ]; then
  if   [ "${SEVEN_INT:-0}" -ge 80 ] 2>/dev/null; then SEVEN_COLOR="$C_BAD"
  elif [ "${SEVEN_INT:-0}" -ge 50 ] 2>/dev/null; then SEVEN_COLOR="$C_WARN"
  else                                                SEVEN_COLOR="$C_GOOD"
  fi
  echo "---"
  echo "  7d  $SEVEN_BAR | font=Menlo size=12 color=$SEVEN_COLOR refresh=true"
  if [ -n "${SEVEN_TIME_BAR:-}" ]; then
    if   [ "${SEVEN_TIME_INT:-0}" -ge 90 ] 2>/dev/null; then SEVEN_TIME_COLOR="$C_BAD"
    elif [ "${SEVEN_TIME_INT:-0}" -ge 75 ] 2>/dev/null; then SEVEN_TIME_COLOR="$C_WARN"
    else                                                     SEVEN_TIME_COLOR="$C_TIME"
    fi
    echo "  ⏱   $SEVEN_TIME_BAR | font=Menlo size=12 color=$SEVEN_TIME_COLOR refresh=true"
  fi
  echo "  Resets  $SEVEN_RESET_STR | font=Menlo size=11 color=$C_DIM refresh=true"
  if [ -n "${SEVEN_MSG:-}" ]; then
    echo "  $SEVEN_MSG | font=Menlo size=11 color=$SEVEN_MSG_COLOR refresh=true"
  fi
fi

echo "---"
if [ -n "$CAP_STATE" ]; then
  echo "🔒 Polling paused — ${CAP_LABEL} reached | font=Menlo size=12 color=$C_INFO"
  echo "  Resumes at ${CAP_LOCAL}  ·  in ${CAP_REMAINING} | font=Menlo size=11 color=$C_DIM"
  echo "  Skipping API calls until reset (prevents 429 spam) | font=Menlo size=11 color=$C_DIM"
  echo "  Force refresh anyway | font=Menlo size=11 color=$C_DIM bash=$PLUGIN_PATH_FULL param1=--force terminal=false refresh=true"
  echo "---"
elif [ -n "$RETRY_REMAINING" ]; then
  echo "⚠ Backing off after rate limit | font=Menlo size=12 color=$C_WARN"
  echo "  Retry at ${RETRY_LOCAL:-?}  ·  in ${RETRY_REMAINING} | font=Menlo size=11 color=$C_DIM"
  if [ "${ERR429_COUNT:-0}" -gt 1 ] 2>/dev/null; then
    echo "  ${ERR429_COUNT} consecutive 429s — exponential backoff active | font=Menlo size=11 color=$C_DIM"
  else
    echo "  Server asked us to slow down | font=Menlo size=11 color=$C_DIM"
  fi
  echo "  Force refresh anyway | font=Menlo size=11 color=$C_DIM bash=$PLUGIN_PATH_FULL param1=--force terminal=false refresh=true"
  echo "---"
fi
echo "Check for update | bash=$PLUGIN_PATH_FULL param1=--update terminal=true font=Menlo size=11"
