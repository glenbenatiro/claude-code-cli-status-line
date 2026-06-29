# claude-code-cli-status-line

A compact, 3-line status bar for [Claude Code CLI](https://claude.ai/code) that shows model info, context window usage, rate-limit pacing, and working directory — all in one glance.

## Example output

```
[sonnet-4-6] [high] [thinking:off]
[ctx: 12% 24k/200k] [5h: used 1% · ≤20% max in 4h31m | 7d: used 8% · ≤57% max in 4d3h]
[v1.0.71] [my-project]
```

The `used X%` number is color-coded based on how much of the pacing ceiling it has consumed (green → yellow → red as it approaches or exceeds the ceiling).

| Line | What it shows |
|------|---------------|
| 1 | Model name (sans `claude-` prefix), effort level, extended thinking on/off |
| 2 | Context window used % and used/total token counts · 5-hour and 7-day rate-limit usage with pacing budget |
| 3 | Claude Code version · current working directory (basename) |

## What the pacing ceiling means

The usage segment shows `used X% · ≤Y% max` for both the 5-hour and 7-day windows.

`≤Y% max` is the **pacing ceiling** — the maximum cumulative usage you should have reached by now to stay on track for even consumption across the full reset window. It is calculated as:

```
ceiling = (elapsed_units + 1) / total_units × 100

  5h window: total_units = 5,  unit = 1 hour
  7d window: total_units = 7,  unit = 1 day
```

The `+1` gives credit for the current unit still being in progress, so in the final hour (or day) the ceiling reaches 100%.

The ceiling updates in discrete steps — hourly for the 5h window, daily for the 7d window — so it acts as a simple "should I be at or below this by now?" check.

The `used X%` number is color-coded by how much of the ceiling the current spend has consumed:

| Spend as % of ceiling | Color  | Meaning               |
|-----------------------|--------|-----------------------|
| 0–70%                 | Green  | Well within pace      |
| 71–99%                | Yellow | Approaching the limit |
| 100%+                 | Red    | At or over limit      |

The statusline refreshes every 5 seconds.

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
| 5h usage | `[5h: used 1% · ≤20% max in 4h31m]` | Used % (color-coded) vs hourly pacing ceiling |
| 7d usage | `[7d: used 8% · ≤57% max in 4d3h]` | Used % (color-coded) vs daily pacing ceiling |
| Version | `[v1.0.71]` | Leftmost on line 3 |
| Directory | `[my-project]` | `basename` of `$CWD` only |
| Branch | `[⎇ main]` | Current git branch from `$CWD`; short SHA if detached; omitted outside a repo. Rightmost on line 3 — first to clip on narrow terminals |

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
