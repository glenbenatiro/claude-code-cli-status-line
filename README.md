# claude-code-cli-status-line

A compact, 3-line status bar for [Claude Code CLI](https://claude.ai/code) that shows model info, context window usage, rate-limit pacing, and working directory — all in one glance.

## Example output

```
[sonnet-4-6] [high] [thinking:off]
[ctx: 12% 24k/200k] [5h: used 1% · 22%/h left in 4h31m | 7d: used 8% · 15%/d left in 4d3h]
[v1.0.71] [my-project]
```

| Line | What it shows |
|------|---------------|
| 1 | Model name (sans `claude-` prefix), effort level, extended thinking on/off |
| 2 | Context window used % and used/total token counts · 5-hour and 7-day rate-limit usage with pacing budget |
| 3 | Claude Code version · current working directory (basename) |

## What the pacing budget means

The usage segment shows `used X% · Y%/h left` (5-hour window) and `used X% · Y%/d left` (7-day window).

The rate is calculated as:

```
rate = remaining_budget / remaining_time_units
     = (100% - used%) / hours_remaining   ← for 5h window
     = (100% - used%) / days_remaining    ← for 7d window
```

This tells you how much of your quota you can burn per remaining hour or day while still spreading usage evenly until the window resets. If the rate is high, you're running low; if it's low, you have headroom.

The statusline refreshes every 5 seconds, so the rate updates continuously as time passes.

## Prerequisites

- [Claude Code CLI](https://claude.ai/code)
- `bash`
- [`jq`](https://jqlang.github.io/jq/) (`brew install jq` / `apt install jq`)

## Installation

### 1. Download the script

```bash
curl -fsSL https://raw.githubusercontent.com/glenbenatiro/claude-code-cli-status-line/main/statusline.sh \
  -o ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

### 2. Configure Claude Code

Open `~/.claude/settings.json` and **merge** the following block into it (do not replace the entire file):

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh",
    "refreshInterval": 5
  }
}
```

> **Note:** `refreshInterval` is in **seconds**. The minimum is `1`. Leave it out to update only on events (assistant messages, `/compact`, permission changes, etc.).

### 3. Restart Claude Code

The status line will appear at the bottom of the terminal after restarting.

## Segment reference

| Segment | Example | Notes |
|---------|---------|-------|
| Model | `[sonnet-4-6]` | Leading `claude-` is stripped |
| Effort | `[high]` | Omitted when data is unavailable |
| Thinking | `[thinking:on]` / `[thinking:off]` | Always shown |
| Context | `[ctx: 12% 24k/200k]` | Used % and used/total token counts (in thousands) |
| 5h usage | `[5h: used 1% · 22%/h left in 4h31m]` | Pacing budget per remaining hour |
| 7d usage | `[7d: used 8% · 15%/d left in 4d3h]` | Pacing budget per remaining day |
| Version | `[v1.0.71]` | Rightmost on line 3 — first to clip on narrow terminals |
| Directory | `[my-project]` | `basename` of `$CWD` only |

## Using this with an LLM assistant

If you are asking an LLM to install or modify this for you, pass it this context:

- The script file goes to `~/.claude/statusline.sh`
- The settings key is `statusLine` (inside `~/.claude/settings.json`)
- `refreshInterval` is **seconds**, not milliseconds, and must be **nested inside `statusLine`** — not at the top level of `settings.json`
- The `command` path must be absolute or use `~` (e.g. `bash ~/.claude/statusline.sh`)
- After editing, `settings.json` must remain valid JSON — merge the `statusLine` block into the existing file, do not replace it
- The script reads JSON from stdin (piped from Claude Code) and writes colored text to stdout — it has no side effects and no credentials

## Customization

The script is plain bash with no external dependencies beyond `jq`. Each display segment is a standalone block — you can add, remove, or reorder them by editing the `line1`, `line2`, and `line3` arrays. Colors use standard ANSI escape codes.

## License

MIT
