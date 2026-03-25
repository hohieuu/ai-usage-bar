# AI Usage Bar

Real-time **Claude Code** and **Cursor** usage in your macOS menu bar via [SwiftBar](https://swiftbar.app).

[Demo](https://youtu.be/PDRUsuuMiMY)


| Claude Code                                    | Cursor                                        |
| ---------------------------------------------- | --------------------------------------------- |
| 5h/7d rate-limit windows, refreshes every 60s | Monthly premium requests, refreshes every 10m |


---

## Install

### Claude Code

**Prerequisites:** [SwiftBar](https://swiftbar.app) (`brew install --cask swiftbar`), Python 3, `jq` (`brew install jq`), Claude Code (must be logged in)

```bash
# One-liner
curl -fsSL https://raw.githubusercontent.com/hohieuu/ai-usage-bar/main/install.sh | bash

# Or clone
git clone https://github.com/hohieuu/ai-usage-bar && bash ai-usage-bar/install.sh
```

### Cursor

**Prerequisites:** [SwiftBar](https://swiftbar.app) (`brew install --cask swiftbar`), Python 3, [Cursor IDE](https://cursor.com) (must be logged in)

```bash
# One-liner
curl -fsSL https://raw.githubusercontent.com/hohieuu/ai-usage-bar/main/cursor-install.sh | bash

# Or clone
git clone https://github.com/hohieuu/ai-usage-bar && bash ai-usage-bar/cursor-install.sh
```


---

## What You See

**Claude Code** — `Sonnet 42%` in menu bar

```
Claude Usage
  5h  ████░░░░░░ 42%        ← rate-limit usage
  ⏱   ██████░░░░ 60%        ← time through window
  Resets  2h 18m  ·  14:00
  7d  █░░░░░░░░░ 7%
  ⏱   ███░░░░░░░ 26%
  Resets  5d 4h  ·  Mon 14:00
  Updated 14:02:35
```

> Model name (`Sonnet`, `Opus`, `Haiku`) comes from the optional statusLine hook. Shows `Claude` if hook is not installed.

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
    participant KC as macOS Keychain
    participant SB as SwiftBar (every 60s)
    participant API as api.anthropic.com
    participant Cache as ~/.claude-usage-bar/cache.json
    participant MB as Menu Bar

    loop Every 60 seconds
        SB->>KC: Read OAuth token
        alt Cache older than 60s
            SB->>API: GET /api/oauth/usage
            API-->>SB: {five_hour, seven_day, utilization, resets_at}
            SB->>Cache: Save response
        end
        Note right of SB: Parse utilization %<br/>Calculate reset countdown
        SB->>MB: Render "Sonnet 42%"
    end
```

```mermaid
sequenceDiagram
    participant CC as Claude Code CLI
    participant Hook as save-usage-status.sh (optional)
    participant Tmp as /tmp/claude-status-*.json
    participant SB as SwiftBar

    CC->>Hook: statusLine event (model name in JSON)
    Hook->>Tmp: Write session file
    Note right of SB: Reads model name<br/>from latest session file
```

> **What gets installed:**
>
> - `<SwiftBar plugins>/claude-usage.60s.sh` — display plugin, calls Anthropic API directly
> - `~/.claude-usage-bar/cache.json` — cached API response (auto-created)
> - `~/.claude/hooks/save-usage-status.sh` *(optional)* — 7-line hook for model name display
> - `~/.claude/settings.json` *(optional)* — adds `statusLine` entry if hook is installed

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
>
> - `<SwiftBar plugins>/cursor-usage.10m.sh` — single file, reads Cursor's existing DB
> - `~/.cursor-usage-bar/cache.json` — cached API response (auto-created)
> - **No config files, no tokens to paste, no hooks** — fully zero-config

---

## Uninstall

```bash
# Claude Code
curl -fsSL https://raw.githubusercontent.com/hohieuu/ai-usage-bar/main/uninstall.sh | bash

# Cursor
curl -fsSL https://raw.githubusercontent.com/hohieuu/ai-usage-bar/main/cursor-uninstall.sh | bash
```
