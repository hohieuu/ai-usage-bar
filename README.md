# AI Usage Bar

Real-time **Claude Code** and **Cursor** usage in your macOS menu bar via [SwiftBar](https://swiftbar.app).

[![Demo](https://img.youtube.com/vi/PDRUsuuMiMY/maxresdefault.jpg)](https://youtu.be/PDRUsuuMiMY)

| Claude Code | Cursor |
|-------------|--------|
| 5h/7d rate-limit windows, resets every 5s | Monthly premium requests, refreshes every 10m |

---

## Install

```bash
git clone https://github.com/hohieuu/claude-usage-bar
cd claude-usage-bar

bash install.sh          # Claude Code
bash cursor-install.sh   # Cursor (zero-config)
```

### Prerequisites

| Tool | Install |
|------|---------|
| [SwiftBar](https://swiftbar.app) | `brew install --cask swiftbar` |
| Python 3 | `brew install python3` (or pre-installed) |
| Claude Code CLI | [claude.ai/download](https://claude.ai/download) (Claude only) |
| Cursor IDE | [cursor.com](https://cursor.com) — must be logged in (Cursor only) |

---

## What You See

**Claude Code** — `Claude - 42%` in menu bar

```
Claude Usage
  5h  ████░░░░░░ 42%        ← rate-limit usage
  ⏱   ██████░░░░ 60%        ← time through window
  Resets  2h 18m  ·  14:00
  7d  █░░░░░░░░░ 7%
  Ctx ████░░░░░░ 45%
```

**Cursor** — `⌘ 620/1000` in menu bar

```
Cursor Usage
  Month ██████░░░░ 62%       ← premium requests
  620 / 1000 premium requests
Billing Cycle
  ⏱   ████████░░ 77%        ← time through month
  Day 24 of 31 · 7d left
Pace
  Avg 25.8 req/day · Budget 54.3 req/day
  Proj. ~800 at month end · ✓ On track
```

---

## How It Works

Everything runs **locally on your Mac**. No data leaves your machine except Cursor's own API call.

### Claude Code

```mermaid
sequenceDiagram
    participant CC as Claude Code CLI
    participant Hook as save-usage-status.sh
    participant Tmp as /tmp/claude-status-*.json
    participant SB as SwiftBar (every 5s)
    participant MB as Menu Bar

    CC->>Hook: statusLine event (JSON via stdin)
    Note right of Hook: Extracts session_id<br/>Writes full JSON
    Hook->>Tmp: Write per-session file
    loop Every 5 seconds
        SB->>Tmp: Read all session files
        Note right of SB: Pick most recent by resets_at<br/>Parse 5h/7d usage %<br/>Calculate reset countdown
        SB->>MB: Render "Claude - 42%"
    end
```

> **What gets installed:**
> - `~/.claude/hooks/save-usage-status.sh` — 7-line hook, reads stdin → writes to `/tmp/`
> - `<SwiftBar plugins>/claude-usage.5s.sh` — display script, reads `/tmp/` files only
> - `~/.claude/settings.json` — adds `statusLine` entry (backed up first)

### Cursor

```mermaid
sequenceDiagram
    participant DB as Cursor Local DB<br/>(state.vscdb)
    participant SB as SwiftBar (every 10m)
    participant API as api2.cursor.sh/auth/usage
    participant Cache as ~/.cursor-usage-bar/cache.json
    participant MB as Menu Bar

    loop Every 10 minutes
        SB->>DB: Read Bearer token<br/>(cursorAuth/accessToken)
        SB->>Cache: Check cache age
        alt Cache older than 10min
            SB->>API: GET with Bearer token
            API-->>SB: {numRequests, maxRequestUsage, startOfMonth}
            SB->>Cache: Save response
        end
        Note right of SB: Calculate usage %, pace,<br/>daily budget, projection
        SB->>MB: Render "⌘ 620/1000"
    end
```

> **What gets installed:**
> - `<SwiftBar plugins>/cursor-usage.10m.sh` — single file, reads Cursor's existing DB
> - `~/.cursor-usage-bar/cache.json` — cached API response (auto-created)
> - **No config files, no tokens to paste, no hooks** — fully zero-config

---

## Uninstall

```bash
bash uninstall.sh          # Claude Code
bash cursor-uninstall.sh   # Cursor
```
