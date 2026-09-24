# claude-code-cli-status-line

A boxed, two-column status line for [Claude Code CLI](https://claude.ai/code). It shows the model, context usage, rate-limit pacing, cost, prompt cache health, and where the session is running, all in one glance. Text is white; bright green, yellow and red are reserved for status, so a color always means something.

## Example output

```
╭────────────────────────────────┬────────────────────────────────╮
│ claude-opus-5-5 · high         │ 2026-09-24 · 17:14:39 +08:00   │
│ ctx 61% 612k/1000k · 39% left  │ 01h 10m 35s · $3.47 (+$0.00)   │
│ 5h 72% (≤60%) · 02h 14m 00s    │ cache warm · 93% hit · 58m 00s │
│ 7d 41% (≤28%) · 5d 08h 00m 00s │ cache w/r 8k/603k · out 2k     │
│                                │ style Explanatory              │
├────────────────────────────────┴────────────────────────────────┤
│ v2.1.281 · 3f9c2a71 · Fix checkout flow                         │
│ dir /home/user/projects/my-project · ◆ my-feature               │
│ cwd /home/user/projects/my-project/web · ⌥ feature-xyz          │
╰─────────────────────────────────────────────────────────────────╯
```

The example is plain text. In a terminal the ctx, limit and cache numbers are colored green, yellow or red (see Colors below).

## What each cell shows

**Left column**

| Row | Example | Source field | Notes |
|-----|---------|--------------|-------|
| Model line | `claude-opus-5-5 · high` | `model.id`, `effort.level` | The raw model ID (a 1M-context model shows as `claude-opus-5-5[1m]`), then the effort level. |
| `ctx` | `ctx 61% 612k/1000k · 39% left` | `context_window.used_percentage`, `total_input_tokens`, `context_window_size`, `remaining_percentage` | Used % and token amount share one color: green under 50%, yellow 50 to 79%, red 80% and above. |
| `5h` | `5h 72% (≤60%) · 02h 14m 00s` | `rate_limits.five_hour.*` | Used %, the pacing ceiling (see below), then the time until reset. |
| `7d` | `7d 41% (≤28%) · 5d 08h 00m 00s` | `rate_limits.seven_day.*` | Same, over the weekly window. |

**Right column**

| Row | Example | Source field | Notes |
|-----|---------|--------------|-------|
| Clock | `2026-09-24 · 16:36:52 +08:00` | the box's own clock | ISO date, time, and UTC offset. Ticks with `refreshInterval`. |
| Runtime and cost | `01h 10m 35s · $3.47 (+$0.00)` | `cost.total_duration_ms`, `cost.total_cost_usd` | The green `(+$…)` is what the latest turn added (see "Cost delta"). |
| `cache` | `cache warm · 93% hit · 58m 00s` | `prompt_cache.*` | `warm` or `cold`, hit rate, and time until the cache expires. When cold, `recache 612k` (the tokens a cold cache would have to rewrite) takes the place of the hit rate, and the time since it went cold replaces the countdown (`-` if unknown). |
| Tokens | `cache w/r 8k/603k · out 2k` | `context_window.current_usage.*` | Last API call: cache written, cache read, then output tokens. |
| `style` | `style Explanatory` | `output_style.name` | Only shown when the style isn't `default`. |

The hit rate is red under 50%, yellow from 50 to 94%, green from 95%.

**Bottom rows (full width)**

| Row | Example | Source field |
|-----|---------|--------------|
| Session | `v2.1.281 · 3f9c2a71 · Fix checkout flow` | `version`, first 8 characters of `session_id`, `session_name` (`unnamed` if unset) |
| `dir` | `dir /home/user/projects/my-project · ◆ my-feature` | `workspace.project_dir` (where Claude Code was launched, fixed for the session), current git branch as `⎇ branch`, and `◆ name` when the session is in a Claude Code worktree session (`worktree.name`) |
| `cwd` | `cwd /home/user/projects/my-project/web · ⌥ feature-xyz` | `workspace.current_dir` (where Claude is working now), and `⌥ name` when that directory is inside any linked git worktree (`workspace.git_worktree`, however it was created). Shown only when it differs from `dir` or a worktree is present. |

The branch, `◆` and `⌥` markers and a `cold` cache label are bright blue. Paths are always shown in full.

### Placeholders

Some values are null or absent at session start and right after `/compact` (context percentages, `current_usage`, cache data, and rate limits before the first response unless another session has shared them, see below). Those render as `-` so every row keeps its place. A real zero still shows as `0`.

## Colors

The line uses five colors and nothing else:

| Color | Used for |
|-------|----------|
| White | All text, separators, borders |
| Bright green | Healthy: cost, low context, on pace, warm cache, hit rate 95%+ |
| Bright yellow | Watch it: ctx 50 to 79%, nearing the pacing ceiling, hit rate 50 to 94% |
| Bright red | Over: ctx 80%+, at or over the pacing ceiling, hit rate under 50% |
| Bright blue | Branch and worktree markers, and a `cold` cache |

Every color reset returns to white rather than the terminal default, so no text falls back to a dim theme color.

## What the pacing ceiling means

The `(≤Y%)` next to each limit is the **pacing ceiling**: the most cumulative usage you should have reached by now to stay on track for even consumption across the whole reset window. It is calculated as:

```
ceiling = (elapsed_units + 1) / total_units × 100

  5h window: total_units = 5,  unit = 1 hour
  7d window: total_units = 7,  unit = 1 day
```

The `+1` gives credit for the current unit still being in progress, so in the final hour (or day) the ceiling reaches 100%. It moves in steps: hourly for the 5h window, daily for the 7d window.

The used % and the ceiling share one color, based on how much of the ceiling has been consumed:

| Used as % of ceiling | Color  | Meaning               |
|----------------------|--------|-----------------------|
| 0 to 70%             | Green  | Well within pace      |
| 71 to 99%            | Yellow | Approaching the limit |
| 100%+                | Red    | At or over limit      |

## Cost delta

Claude Code only reports the session's total cost, and a status line command has no memory between runs. To show what the latest turn added, the script keeps one small file per session at:

```
${XDG_STATE_HOME:-~/.local/state}/claude-statusline/<session_id>
```

It holds the current `prompt_id`, the cost when that turn began, and the last cost seen. A new `prompt_id` means a new turn, so the last cost becomes the baseline. A cost lower than the baseline (after `/clear`) resets it. The files are tiny and safe to delete at any time; the delta just restarts from zero.

## Shared rate limits

The 5h and 7d limits belong to your account, but a session only learns them from its own API responses. A session that has been idle for days keeps showing the numbers from its last response. To keep those numbers fresh, every status line run records the limits it sees in a small file, and each session shows the freshest values any session on the machine has seen:

```
${CLAUDE_CONFIG_DIR:-~/.claude}/statusline-rate-limits
```

It holds two lines (`five <used %> <resets_at>` and `seven <used %> <resets_at>`), only percentages and timestamps, with mode 600. For each window the newer window (later reset time) wins, and within the same window the higher used % wins, because usage only climbs until the window resets. Expired entries are ignored. A brand-new session, or one just after `/compact`, shows the shared values instead of `-`. The pacing ceiling and reset countdown are computed from the merged values as usual.

It only helps while another session is active on the same machine and account. With no session running, nothing refreshes the numbers. The file is safe to delete at any time, and `CLAUDE_CONFIG_DIR` keeps separate accounts apart.

## Prerequisites

- [Claude Code CLI](https://claude.ai/code)
- `bash` 4.2 or newer, with a UTF-8 locale (any current Linux; on macOS install a newer bash with Homebrew)
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
    "refreshInterval": 1
  }
}
```

> **Note:** `refreshInterval` is in **seconds** and the minimum is `1`. One second keeps the clock and the countdowns ticking. Leave it out to update only on events (assistant messages, `/compact`, permission changes, and so on).

### 3. Restart Claude Code

The status line appears at the bottom of the terminal after restarting.

## Previewing changes

`preview.sh` renders the status line against the sample payloads in `fixtures/`, with reset and cache timestamps shifted to realistic offsets. It uses temporary state and config directories, so it never touches your real cost state or shared rate-limit file.

```bash
./preview.sh              # all fixtures
./preview.sh full         # one fixture: real-session, full, or early
PLAIN=1 ./preview.sh      # strip colors
```

- `real-session`: a payload captured from a live session
- `full`: every field populated, including a worktree and a non-default output style
- `early`: a brand-new session, where most values are null

The field reference is the [Claude Code status line docs](https://code.claude.com/docs/en/statusline).

## Using this with an LLM assistant

If you are asking an LLM to install or modify this for you, pass it this context:

- The script file goes to `~/.claude/statusline.sh`
- The settings key is `statusLine` (inside `~/.claude/settings.json`)
- `refreshInterval` is **seconds**, not milliseconds, and must be **nested inside `statusLine`**, not at the top level of `settings.json`
- The `command` path must be absolute or use `~` (e.g. `bash ~/.claude/statusline.sh`)
- After editing, `settings.json` must remain valid JSON. Merge the `statusLine` block into the existing file; do not replace it
- The script reads JSON from stdin (piped from Claude Code) and writes colored text to stdout. It needs no credentials. Its only side effects are two small files: the per-session cost state file and the shared rate-limit file, both described above

## Customization

The script is plain bash and needs nothing beyond `jq`. Because it runs every second, it avoids starting processes: each refresh runs one `jq` and otherwise stays inside bash. Helpers return their result in `REPLY` (or `PADDED`) rather than printing into `$(...)`, which would fork a subshell each time, so keep that pattern when adding cells. Fields are parsed in one `jq` pass at the top; each cell of the table is built in `design_table` near the bottom. To add, remove, or reorder rows, edit the `V` (left column) and `V2` (right column) arrays there. Colors are ANSI codes defined once at the top. Run `./preview.sh` after any change.

## License

MIT
