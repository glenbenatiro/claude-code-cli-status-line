#!/usr/bin/env bash
# Claude Code status line. Reads session JSON on stdin, prints the status line.
# Reference: https://code.claude.com/docs/en/statusline
#
# Any argument is ignored (older settings pass "table").
#
# It runs every second, so it avoids starting processes: helpers set variables (REPLY or a named
# one) instead of printing into $(...), which would fork a subshell each time. Per refresh it
# starts one jq, and otherwise only touches the filesystem when a state file changes.
# extglob must be on before main is read, because vw() uses an extglob pattern.
shopt -s extglob
# Files this script creates (the cost state and the shared rate-limit file) are private to the user.
umask 077

# Everything runs inside main, which bash reads in full before running any of it. Replacing this file
# while a session is running it (an update) then can't make that run execute half old, half new code.
main() {
# Padding uses ${#var}, which counts bytes unless the locale is UTF-8. Git Bash on Windows often
# starts with no locale, so "·" and "≤" would count as 2-3 columns and the borders would go jagged.
case "${LC_ALL:-${LC_CTYPE:-$LANG}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;; *) export LC_ALL=C.UTF-8 ;; esac

# The shared rate-limit file (see "Shared rate limits" below) is read here, with a builtin, so the one
# jq call can parse it too. Anything near 8 KB is far bigger than this script ever writes: ignore it,
# and the next write replaces it.
cfg_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
rl_file="$cfg_dir/statusline-rate-limits.json"
rl_json=""
[ -f "$rl_file" ] && [ -r "$rl_file" ] && IFS= read -r -N 8192 rl_json < "$rl_file"
[ "${#rl_json}" -ge 8192 ] && rl_json=""

# ---------------------------------------------------------------------------
# Parse every field in one jq pass. @sh quotes each value so eval is safe.
# Missing/null fields become empty strings, and so does a number field holding anything but a number
# of sane size, so one bad value can't stop jq halfway or break the bash arithmetic later.
# $sh is the shared file: an object, or null when it is missing, empty or not JSON.
# MSYS2_ARG_CONV_EXCL stops Git Bash on Windows rewriting arguments that look like paths.
# ---------------------------------------------------------------------------
eval "$(MSYS2_ARG_CONV_EXCL='*' jq -r --arg rl "$rl_json" '
  def s(f): (try f catch null) as $x | if $x == null then "" else ($x | tostring) end | @sh;
  def n(f): (try f catch null) as $x | if ($x | type) == "number" and $x > -1e15 and $x < 1e15 then ($x | round | tostring) else "" end | @sh;
  (if $rl == "" then null else ([try ($rl | fromjson)] | .[0]) end | if type == "object" then . else null end) as $sh |
  "model=\(s(.model.id // .model.display_name))",
  "effort=\(s(.effort.level))",
  "sname=\(s(.session_name))",
  "sid=\(s(.session_id))",
  "prompt_id=\(s(.prompt_id))",
  "ver=\(s(.version))",
  "cost_u=\(n(.cost.total_cost_usd * 1000000))",
  "dur_ms=\(n(.cost.total_duration_ms))",
  "cwd=\(s(.workspace.current_dir))",
  "proj=\(s(.workspace.project_dir))",
  "git_wt=\(s(.workspace.git_worktree))",
  "wt_name=\(s(.worktree.name))",
  "ctx_used=\(n(.context_window.used_percentage))",
  "ctx_rem=\(n(.context_window.remaining_percentage))",
  "ctx_size=\(n(.context_window.context_window_size))",
  "in_tok=\(n(.context_window.total_input_tokens))",
  "cu_cw=\(n(.context_window.current_usage.cache_creation_input_tokens))",
  "cu_cr=\(n(.context_window.current_usage.cache_read_input_tokens))",
  "cu_out=\(n(.context_window.current_usage.output_tokens))",
  "o5p=\(n(.rate_limits.five_hour.used_percentage))",
  "o5r=\(n(.rate_limits.five_hour.resets_at))",
  "o7p=\(n(.rate_limits.seven_day.used_percentage))",
  "o7r=\(n(.rate_limits.seven_day.resets_at))",
  "fver=\(n($sh.version))",
  "f5p=\(n($sh.five_hour.used_percentage))",
  "f5r=\(n($sh.five_hour.resets_at))",
  "f5t=\(n($sh.five_hour.observed_at))",
  "f5s=\(s($sh.five_hour.session_id))",
  "f7p=\(n($sh.seven_day.used_percentage))",
  "f7r=\(n($sh.seven_day.resets_at))",
  "f7t=\(n($sh.seven_day.observed_at))",
  "f7s=\(s($sh.seven_day.session_id))",
  "pc=\(s(if .prompt_cache then true else null end))",
  "pc_obs=\(s(.prompt_cache.caching_observed))",
  "pc_warm=\(s(.prompt_cache.warm))",
  "pc_exp=\(n(.prompt_cache.expires_at))",
  "pc_hit=\(n(.prompt_cache.hit_ratio * 100))",
  "pc_recache=\(n(.prompt_cache.recache_tokens_if_cold))"
' 2>/dev/null)"
# The session id names a state file and goes into the shared file, so accept only what a real id uses.
[[ "$sid" =~ ^[A-Za-z0-9_-]+$ ]] || sid=""

printf -v now '%(%s)T' -1

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
# White text, plus bright green, yellow and red for status, and blue for the branch, worktree and cold-cache markers.
# RST resets *to white*, not to the terminal default, so uncolored text is white too.
WHITE=$'\033[97m'
RST=$'\033[0;97m'
RED=$'\033[91m' GREEN=$'\033[92m' YELLOW=$'\033[93m'
# Everything else (labels, separators, borders) is white.
BLUE=$'\033[38;2;95;175;255m'
GRAY=$WHITE BORDER=$WHITE

# ---------------------------------------------------------------------------
# Formatting helpers. Each prints nothing when its input is empty.
# ---------------------------------------------------------------------------

# Token count: 16, 64k, 1M, 1.5M
fmt_tok() {
  local n="$1"; REPLY=""; [ -z "$n" ] && return
  if [ "$n" -ge 1000000 ]; then
    local w=$(( n / 1000000 )) f=$(( n % 1000000 / 100000 ))
    if [ "$f" -eq 0 ]; then REPLY="${w}M"; else REPLY="${w}.${f}M"; fi
  elif [ "$n" -ge 1000 ]; then
    REPLY="$(( (n + 500) / 1000 ))k"
  else
    REPLY="$n"
  fi
}

# Whole seconds as 02h 03m 39s (a day or more: 5d 10h 12m 08s). Hours, minutes and seconds are
# always zero-padded so the width stays steady while it ticks.
fmt_hms() {
  local s="$1"; REPLY=""; [ -z "$s" ] && return
  local d=$(( s / 86400 )) h=$(( s % 86400 / 3600 )) m=$(( s % 3600 / 60 )) sec=$(( s % 60 ))
  if [ "$d" -gt 0 ]; then printf -v REPLY '%dd %02dh %02dm %02ds' "$d" "$h" "$m" "$sec"
  else printf -v REPLY '%02dh %02dm %02ds' "$h" "$m" "$sec"
  fi
}

# Time until a Unix epoch, as fmt_hms. Nothing if already past.
fmt_until_hms() {
  local t="$1"; REPLY=""; [ -z "$t" ] && return
  local s=$(( t - now )); [ "$s" -le 0 ] && return
  fmt_hms "$s"
}

# Same, minutes and seconds only (58m 12s). Cache lifetimes top out at 1h, so no hours.
fmt_until_ms() {
  local t="$1"; REPLY=""; [ -z "$t" ] && return
  local s=$(( t - now )); [ "$s" -le 0 ] && return
  printf -v REPLY '%02dm %02ds' $(( s / 60 )) $(( s % 60 ))
}

# Color for a "how full" percentage: green < 50, yellow < 80, red otherwise
level_color() {
  local p="${1:-0}"
  if   [ "$p" -ge 80 ]; then REPLY="$RED"
  elif [ "$p" -ge 50 ]; then REPLY="$YELLOW"
  else REPLY="$GREEN"
  fi
}

# Pacing ceiling: the max usage% you should have reached by now for even
# consumption across the full period. Args: resets_at, unit_secs, total_units
pace_ceiling() {
  local resets_at="$1" unit_secs="$2" total_units="$3"
  REPLY=""; [ -z "$resets_at" ] && return
  local left=$(( resets_at - now )); [ "$left" -le 0 ] && return
  local elapsed=$(( unit_secs * total_units - left )); [ "$elapsed" -lt 0 ] && elapsed=0
  local ceiling=$(( (elapsed / unit_secs + 1) * 100 / total_units ))
  [ "$ceiling" -gt 100 ] && ceiling=100
  REPLY="$ceiling"
}

# Color for used% against its pacing ceiling: green, yellow at 71%+ of it, red at/over it
pace_color() {
  local used="${1:-0}" ceiling="$2"
  [ -z "$ceiling" ] && { REPLY="$WHITE"; return; }
  local ratio=$(( used * 100 / ceiling ))
  if   [ "$ratio" -ge 100 ]; then REPLY="$RED"
  elif [ "$ratio" -ge 71 ];  then REPLY="$YELLOW"
  else REPLY="$GREEN"
  fi
}

# Display width of a string, ignoring color codes. Pure bash for the characters this line uses.
# Anything else non-ASCII (a session name or path in another script, emoji, wide characters)
# falls back to wc -L, which knows real character widths.
vw_utf8=0; vw_probe='·'; [ "${#vw_probe}" -eq 1 ] && vw_utf8=1
vw() {
  local t="${1//$'\033['*([0-9;])m/}" rest
  if [ "$vw_utf8" = 1 ]; then
    rest="${t//[·≤─│]/}"
    if [[ "$rest" != *[![:ascii:]]* ]]; then REPLY=${#t}; return; fi
  fi
  REPLY=$(printf '%s' "$t" | wc -L)
}

# Pad a string with spaces to a display width, into PADDED. An already measured width can be
# passed as the third argument so the string isn't measured again.
pad() { if [ -n "$3" ]; then REPLY=$3; else vw "$1"; fi; local n=$(( $2 - REPLY )); [ "$n" -lt 0 ] && n=0; printf -v PADDED '%s%*s' "$1" "$n" ''; }

# Join non-empty arguments with a separator.
join_by() { local sep="$1"; shift; local x; REPLY=""; for x in "$@"; do [ -z "$x" ] && continue; REPLY+="${REPLY:+$sep}$x"; done; }

# ---------------------------------------------------------------------------
# Pieces shown in the table
# ---------------------------------------------------------------------------
sid_short="${sid:0:8}"
# Formatted from whole micro-dollars rather than with printf %.2f, which reads the number with the
# locale's decimal separator and fails where that is a comma.
cost_fmt=""
if [ -n "$cost_u" ]; then
  c=$(( (cost_u + 5000) / 10000 )); [ "$c" -lt 0 ] && c=0   # to cents
  printf -v cost_fmt '$%d.%02d' $(( c / 100 )) $(( c % 100 ))
fi

# Cost added by the most recent turn. The status line is stateless, so remember per session the
# cost when the current prompt began (= the last cost seen before prompt_id changed).
# Costs are kept in whole micro-dollars so the math stays in bash. The same file keeps this session's
# last 5h and 7d readings, to tell when the session is fresh (see "Shared rate limits" below).
cost_delta_fmt="" state_file="" rl_fresh=0
if [ -n "$sid" ] && [ -n "$cost_u" ]; then
  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/claude-statusline"
  state_file="$state_dir/$sid"
  st_prompt="" st_start="" st_last="" st_r5p="" st_r5r="" st_r7p="" st_r7r=""
  [ -r "$state_file" ] && read -r st_prompt st_start st_last st_r5p st_r5r st_r7p st_r7r _ < "$state_file"
  # Files from older versions stored dollars as decimals; start a fresh baseline for those.
  [[ "$st_start" =~ ^[0-9]+$ && "$st_last" =~ ^[0-9]+$ ]] || st_prompt=""
  # Fresh: this session has just heard from the API, so its 5h and 7d readings are the newest anywhere.
  # Its cost only goes up when a response arrives, and a response can also change a reading without
  # costing anything (a 429). A reading that disappears is Claude Code dropping a window at its reset,
  # not news. Files from older versions keep no readings (3 fields), so after an upgrade a session
  # isn't fresh until its cost goes up or a reading changes.
  if [ -n "$st_prompt" ]; then
    [ "$cost_u" -gt "$st_last" ] && rl_fresh=1
    if [ -n "$st_r7r" ]; then
      [ -n "$o5p" ] && [ "$o5p ${o5r:--}" != "$st_r5p $st_r5r" ] && rl_fresh=1
      [ -n "$o7p" ] && [ "$o7p ${o7r:--}" != "$st_r7p $st_r7r" ] && rl_fresh=1
    fi
  fi
  # The state file is space-separated, so keep the prompt id to characters a real id uses.
  cur_prompt="${prompt_id//[^A-Za-z0-9_-]/}"; cur_prompt="${cur_prompt:--}"
  if   [ -z "$st_prompt" ];              then turn_start="$cost_u"     # no baseline yet
  elif [ "$cur_prompt" != "$st_prompt" ]; then turn_start="$st_last"    # new turn began
  else                                        turn_start="$st_start"
  fi
  # A cost lower than the baseline means the session's cost was reset (/clear)
  [ "$cost_u" -lt "$turn_start" ] && turn_start=0
  d=$(( cost_u - turn_start )); [ "$d" -lt 0 ] && d=0
  d=$(( (d + 5000) / 10000 ))   # to cents
  printf -v cost_delta_fmt '$%d.%02d' $(( d / 100 )) $(( d % 100 ))
fi
dur_fmt=""; [ -n "$dur_ms" ] && { fmt_hms $(( dur_ms / 1000 )); dur_fmt="$REPLY"; }

level_color "${ctx_used:-0}"; ctx_c="$REPLY"

# ---------------------------------------------------------------------------
# Shared rate limits
# ---------------------------------------------------------------------------
# The 5h and 7d limits belong to the account, not the session, and a session only learns them from its
# own API responses, so an idle session keeps showing old numbers. Sessions share them through
# statusline-rate-limits.json in the Claude config dir (read near the top):
#   { "version": 1,
#     "five_hour": { "used_percentage": 1, "resets_at": <epoch>, "observed_at": <epoch>, "session_id": "..." },
#     "seven_day": { ... } }
# Only a fresh session writes it, so it always holds the newest reading any session has had. Every
# other session shows the file's reading, and its own only when the file has none for that window.
# observed_at (when a fresh session last confirmed the value) and session_id (which session) are for
# people reading the file; nothing here compares times, so a clock that jumps can't mislead it.
rl_ver=1 rl_newer=0 f5ok=0 f7ok=0

# rl_valid_entry pct resets_at observed_at session: true when a file entry is usable
rl_valid_entry() {
  [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ && "$3" =~ ^[0-9]+$ && "$4" =~ ^[A-Za-z0-9_-]+$ ]] && [ "$2" -gt "$now" ]
}
if [ "$fver" = "$rl_ver" ]; then
  rl_valid_entry "$f5p" "$f5r" "$f5t" "$f5s" && f5ok=1
  rl_valid_entry "$f7p" "$f7r" "$f7t" "$f7s" && f7ok=1
elif [[ "$fver" =~ ^[0-9]+$ ]] && [ "$fver" -gt "$rl_ver" ]; then
  rl_newer=1   # written by a newer version of this script: don't use it, and don't overwrite it
fi

# pick_limit own_pct own_reset file_ok file_pct file_reset file_observed -> RL_P RL_R to show, and
# RL_WRITE=1 when this session should write its reading to the file
pick_limit() {
  local op="$1" or="$2" fok="$3" fp="$4" fr="$5" ft="$6" own_ok=0
  RL_WRITE=0
  [[ "$op" =~ ^[0-9]+$ && "$or" =~ ^[0-9]+$ ]] && [ "$or" -gt "$now" ] && own_ok=1
  if [ "$own_ok" = 1 ] && [ "$rl_fresh" = 1 ]; then
    RL_P="$op" RL_R="$or"
    # Write when the file differs, or hasn't been confirmed for a minute: that keeps observed_at
    # current without a write on every response.
    if [ "$fok" = 0 ] || [ "$op" != "$fp" ] || [ "$or" != "$fr" ] || [ $(( now - ft )) -ge 60 ]; then RL_WRITE=1; fi
  elif [ "$fok" = 1 ];    then RL_P="$fp" RL_R="$fr"
  elif [ "$own_ok" = 1 ]; then RL_P="$op" RL_R="$or"
  else RL_P="" RL_R=""
  fi
}
pick_limit "$o5p" "$o5r" "$f5ok" "$f5p" "$f5r" "$f5t"; five_pct="$RL_P"  five_reset="$RL_R"  w5=$RL_WRITE
pick_limit "$o7p" "$o7r" "$f7ok" "$f7p" "$f7r" "$f7t"; seven_pct="$RL_P" seven_reset="$RL_R" w7=$RL_WRITE

# rl_entry key pct resets_at observed_at session: append one window's entry to rl_out
rl_entry() { printf -v REPLY ',\n  "%s": { "used_percentage": %s, "resets_at": %s, "observed_at": %s, "session_id": "%s" }' "$@"; rl_out+="$REPLY"; }

# Write each window from this session's reading when it has a newer one, else keep the file's entry.
# Every value is a validated number or session id, so printf can't produce broken JSON. A failed write
# leaves the cost state unsaved (rl_saved=0), so the next run is fresh again and retries. A config dir
# that can't be written to is not retried, since that would cost a process every second.
rl_saved=1
if [ "$w5$w7" != 00 ] && [ "$rl_newer" = 0 ] && [ -w "$cfg_dir" ]; then
  rl_out="{"$'\n'"  \"version\": $rl_ver"
  if   [ "$w5" = 1 ];   then rl_entry five_hour "$o5p" "$o5r" "$now" "$sid"
  elif [ "$f5ok" = 1 ]; then rl_entry five_hour "$f5p" "$f5r" "$f5t" "$f5s"; fi
  if   [ "$w7" = 1 ];   then rl_entry seven_day "$o7p" "$o7r" "$now" "$sid"
  elif [ "$f7ok" = 1 ]; then rl_entry seven_day "$f7p" "$f7r" "$f7t" "$f7s"; fi
  rl_out+=$'\n}\n'
  rl_tmp="$rl_file.tmp.$$"
  { printf '%s' "$rl_out" > "$rl_tmp" && mv -f "$rl_tmp" "$rl_file"; } 2>/dev/null || { rl_saved=0; [ -e "$rl_tmp" ] && rm -f "$rl_tmp" 2>/dev/null; }
fi
# Versions before the JSON file shared a two-line text file. Nothing reads it now, so remove it once.
[ -e "$cfg_dir/statusline-rate-limits" ] && [ -w "$cfg_dir" ] && rm -f "$cfg_dir/statusline-rate-limits" 2>/dev/null

# Save the cost state only now. Claude Code kills a run when a newer update arrives; saving it earlier
# would mark this response as seen even if the run died before sharing its readings.
if [ -n "$state_file" ] && [ "$rl_saved" = 1 ]; then
  st_new="$cur_prompt $turn_start $cost_u ${o5p:--} ${o5r:--} ${o7p:--} ${o7r:--}"
  if [ "$st_new" != "$st_prompt $st_start $st_last $st_r5p $st_r5r $st_r7p $st_r7r" ]; then
    if [ ! -e "$state_file" ]; then
      # A new session: create the folder if needed, and tidy up once rather than on every refresh:
      # state files untouched for 30 days, and shared-file temp files left by runs killed mid-write.
      # Only when the folder is writable: otherwise the file never appears and this would run every time.
      [ -d "$state_dir" ] || mkdir -p "$state_dir" 2>/dev/null
      if [ -w "$state_dir" ]; then
        find "$state_dir" -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null
        find "$cfg_dir" -maxdepth 1 -type f -name 'statusline-rate-limits.json.tmp.*' -mmin +60 -delete 2>/dev/null
      fi
    fi
    { printf '%s\n' "$st_new" > "$state_file"; } 2>/dev/null
  fi
fi

pace_ceiling "$five_reset" 3600 5;    five_ceil="$REPLY"
pace_ceiling "$seven_reset" 86400 7;  seven_ceil="$REPLY"
pace_color "$five_pct" "$five_ceil";   five_c="$REPLY"
pace_color "$seven_pct" "$seven_ceil"; seven_c="$REPLY"
fmt_until_hms "$five_reset";  five_in="$REPLY"
fmt_until_hms "$seven_reset"; seven_in="$REPLY"

# Context: 61% 612k/1000k · 39% left · 2k out
in_k="$(( (${in_tok:-0} + 500) / 1000 ))k" size_k="$(( (${ctx_size:-0} + 500) / 1000 ))k"
ctx_amount=""
[ -n "$ctx_used" ] && ctx_amount="${ctx_used}% ${in_k}/${size_k}"
ctx_txt=""
if [ -n "$ctx_used" ]; then
  ctx_txt="${ctx_c}${ctx_amount}${RST}${GRAY} · ${ctx_rem}% left${RST}"
fi

# Current time, ticks with refreshInterval
printf -v clock_txt '%(%F · %H:%M:%S)T' -1
printf -v tz '%(%z)T' -1
clock_txt+=" ${tz:0:3}:${tz:3}"

# Rate limits: 5h 72% 2h14m
# Each limit: used% (pace allowance) time until reset, e.g. 4% (≤60%) 2h 38m. The used% and allowance share one color.
five_txt="";  [ -n "$five_pct" ]  && five_txt="${five_c}${five_pct}%${five_ceil:+ (≤${five_ceil}%)}${RST}${GRAY}${five_in:+ · ${five_in}}${RST}"
seven_txt=""; [ -n "$seven_pct" ] && seven_txt="${seven_c}${seven_pct}%${seven_ceil:+ (≤${seven_ceil}%)}${RST}${GRAY}${seven_in:+ · ${seven_in}}${RST}"

# Prompt cache: warm · 93% hit · 58m 12s (cold: blue, recache tokens in place of the hit rate, time since it went cold)
# Hit rate color: under 50 red, 50-94 yellow, 95+ green.
hit_color() {
  if   [ "$1" -ge 95 ]; then REPLY="$GREEN"
  elif [ "$1" -ge 50 ]; then REPLY="$YELLOW"
  else REPLY="$RED"
  fi
}
fmt_until_ms "$pc_exp"; pc_exp_in="$REPLY"
cache_txt=""
if [ "$pc_obs" = "true" ]; then
  D="${GRAY} · ${RST}"
  if [ "$pc_warm" = "true" ]; then cache_txt="${GREEN}warm${RST}"; else cache_txt="${BLUE}cold${RST}"; fi
  # A cold cache shows what it would cost to rebuild in the hit-rate slot.
  if [ "$pc_warm" != "true" ] && [ -n "$pc_recache" ]; then fmt_tok "$pc_recache"; cache_txt+="${D}${YELLOW}recache ${REPLY}${RST}"
  elif [ -n "$pc_hit" ]; then hit_color "$pc_hit"; cache_txt+="${D}${REPLY}${pc_hit}% hit${RST}"
  else cache_txt+="${D}- hit"; fi
  # Warm: time until it goes cold. Cold: time since it went cold (from expires_at), or "-" if unknown.
  if [ "$pc_warm" = "true" ]; then cache_txt+="${D}${GRAY}${pc_exp_in:--}${RST}"
  else
    cold_for=""; [ "${pc_exp:-0}" -gt 0 ] && [ "$now" -gt "$pc_exp" ] && { fmt_hms $(( now - pc_exp )); cold_for="$REPLY"; }
    cache_txt+="${D}${GRAY}${cold_for:--}${RST}"
  fi
elif [ -n "$pc" ]; then
  cache_txt="${GRAY}not observed${RST}"
fi

# Where: full launch path, then full cwd when different, branch, worktrees
# The branch is read straight from .git/HEAD (a linked worktree's .git is a file pointing at its
# git dir), so no git process runs. Unusual setups fall back to git itself.
git_branch=""
if [ -n "$cwd" ]; then
  gd="${cwd//\\//}"  # Windows: C:\a\b -> C:/a/b, so the walk-up below can strip segments
  while [ -n "$gd" ] && [ ! -e "$gd/.git" ]; do
    [[ "$gd" == */* ]] || { gd=""; break; }
    gd="${gd%/*}"
  done
  if [ -n "$gd" ]; then
    head=""
    if [ -d "$gd/.git" ]; then read -r head < "$gd/.git/HEAD" 2>/dev/null
    elif read -r gl < "$gd/.git" 2>/dev/null && [[ "$gl" == "gitdir: "* ]]; then
      gl="${gl#gitdir: }"; [[ "$gl" == /* || "$gl" == [A-Za-z]:* ]] || gl="$gd/$gl"
      read -r head < "$gl/HEAD" 2>/dev/null
    fi
    if   [[ "$head" == "ref: refs/heads/"* && "$head" != *"/.invalid" ]]; then git_branch="${head#ref: refs/heads/}"
    elif [[ "$head" =~ ^[0-9a-f]{40,64}$ ]]; then git_branch="${head:0:7}"
    else
      git_branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
      [ "$git_branch" = "HEAD" ] && git_branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
    fi
  fi
fi
where_txt="dir ${proj:-${cwd:--}}"
cwd_txt=""
if [ -n "$cwd" ] && { [ -n "$git_wt" ] || { [ -n "$proj" ] && [ "$cwd" != "$proj" ]; }; }; then
  cwd_txt="cwd ${cwd}"
fi
[ -n "$git_branch" ] && where_txt+="${GRAY} · ${RST}${BLUE}br ${git_branch}${RST}"
[ -n "$git_wt" ]     && cwd_txt+="${GRAY} · ${RST}${BLUE}git-wt ${git_wt}${RST}"
[ -n "$wt_name" ]    && where_txt+="${GRAY} · ${RST}${BLUE}wt ${wt_name}${RST}"

session_txt="${sname:-${GRAY}unnamed${RST}}"
cost_txt="${cost_fmt:+${GREEN}${cost_fmt}${RST}}${cost_delta_fmt:+ ${GREEN}(+${cost_delta_fmt})${RST}}"

# ---------------------------------------------------------------------------
# table: two label/value column pairs inside a rounded box.
# ---------------------------------------------------------------------------
design_table() {
  local V=() V2=() D="${GRAY} · ${RST}"
  V+=("${model:--}${D}${effort:--}")
  # Null/absent values (session start, after /compact) show "-"
  local ctx_line
  if [ -n "$ctx_txt" ]; then ctx_line="$ctx_txt"
  else ctx_line="${GRAY}- ${in_k}/${size_k} · - left${RST}"; fi
  V+=("ctx ${ctx_line}")
  V+=("5h ${five_txt:--}")
  V+=("7d ${seven_txt:--}")

  V2+=("$clock_txt")
  V2+=("${dur_fmt:--} · ${cost_txt:--}")
  V2+=("cache ${cache_txt:--}")
  local cw="-" cr="-" co="-"
  [ -n "$cu_cw" ]  && { fmt_tok "$cu_cw";  cw="$REPLY"; }
  [ -n "$cu_cr" ]  && { fmt_tok "$cu_cr";  cr="$REPLY"; }
  [ -n "$cu_out" ] && { fmt_tok "$cu_out"; co="$REPLY"; }
  V2+=("cache w/r ${cw}/${cr} · out ${co}")
  local vtxt="-"; [ -n "$ver" ] && vtxt="v$ver"
  join_by "$D" "${GRAY}${vtxt}${RST}" "${GRAY}${sid_short:--}${RST}" "$session_txt"; local sess_txt="$REPLY"

  local rows=${#V[@]}; [ ${#V2[@]} -gt "$rows" ] && rows=${#V2[@]}
  # Measure every cell once; the widths size the columns and then pad the cells.
  local w1=0 w2=0 i x W1=() W2=()
  for x in "${V[@]}";  do vw "$x"; W1+=("$REPLY"); (( REPLY > w1 )) && w1=$REPLY; done
  for x in "${V2[@]}"; do vw "$x"; W2+=("$REPLY"); (( REPLY > w2 )) && w2=$REPLY; done
  # The paths span the full width in their own rows; widen the right column if they need more.
  local wall=$(( w1 + w2 + 3 )) need=0 ws ww wc
  vw "$sess_txt"; ws=$REPLY; vw "$where_txt"; ww=$REPLY; vw "$cwd_txt"; wc=$REPLY
  for x in $ws $ww $wc; do (( x > need )) && need=$x; done
  (( need > wall )) && w2=$(( w2 + need - wall ))
  wall=$(( w1 + w2 + 3 ))

  # A run of n box-drawing dashes, into REPLY.
  dash() { printf -v REPLY '%*s' "$1" ''; REPLY="${REPLY// /─}"; }
  local B="${BORDER}│${RST}" out="" d1 d2 p1
  dash $((w1+2)); d1="$REPLY"; dash $((w2+2)); d2="$REPLY"
  out+="${BORDER}╭${d1}┬${d2}╮${RST}"$'\n'
  for (( i = 0; i < rows; i++ )); do
    pad "${V[i]:-}" $w1 "${W1[i]:-0}"; p1="$PADDED"; pad "${V2[i]:-}" $w2 "${W2[i]:-0}"
    out+="$B $p1 $B $PADDED $B"$'\n'
  done
  out+="${BORDER}├${d1}┴${d2}┤${RST}"$'\n'
  pad "$sess_txt" "$wall" "$ws";  out+="$B $PADDED $B"$'\n'
  pad "$where_txt" "$wall" "$ww"; out+="$B $PADDED $B"$'\n'
  [ -n "$cwd_txt" ] && { pad "$cwd_txt" "$wall" "$wc"; out+="$B $PADDED $B"$'\n'; }
  dash $(( wall + 2 )); out+="${BORDER}╰${REPLY}╯${RST}"
  printf '%s' "$out"
}

printf '%s' "$WHITE"
design_table
printf '\033[0m'
}

main "$@"; exit
