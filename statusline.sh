#!/usr/bin/env bash
# Claude Code status line. Reads session JSON on stdin, prints the status line.
# Reference: https://code.claude.com/docs/en/statusline
#
# Any argument is ignored (older settings pass "table").
input=$(cat)

# ---------------------------------------------------------------------------
# Parse every field in one jq pass. @sh quotes each value so eval is safe.
# Missing/null fields become empty strings.
# ---------------------------------------------------------------------------
eval "$(jq -r '
  def s(f): (try f catch null) as $x | if $x == null then "" else ($x | tostring) end | @sh;
  def n(f): (try f catch null) as $x | if $x == null then "" else ($x | round | tostring) end | @sh;
  "model=\(s(.model.display_name // .model.id))",
  "effort=\(s(.effort.level))",
  "thinking=\(s(.thinking.enabled))",
  "fast=\(s(.fast_mode))",
  "style=\(s(.output_style.name))",
  "sname=\(s(.session_name))",
  "sid=\(s(.session_id))",
  "prompt_id=\(s(.prompt_id))",
  "ver=\(s(.version))",
  "cost=\(s(.cost.total_cost_usd))",
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
  "five_pct=\(n(.rate_limits.five_hour.used_percentage))",
  "five_reset=\(n(.rate_limits.five_hour.resets_at))",
  "seven_pct=\(n(.rate_limits.seven_day.used_percentage))",
  "seven_reset=\(n(.rate_limits.seven_day.resets_at))",
  "pc=\(s(if .prompt_cache then true else null end))",
  "pc_obs=\(s(.prompt_cache.caching_observed))",
  "pc_warm=\(s(.prompt_cache.warm))",
  "pc_exp=\(n(.prompt_cache.expires_at))",
  "pc_hit=\(n(.prompt_cache.hit_ratio * 100))",
  "pc_recache=\(n(.prompt_cache.recache_tokens_if_cold))"
' <<<"$input" 2>/dev/null)"

now=$(date +%s)

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
  local n="$1"; [ -z "$n" ] && return
  if [ "$n" -ge 1000000 ]; then
    local w=$(( n / 1000000 )) f=$(( n % 1000000 / 100000 ))
    [ "$f" -eq 0 ] && echo "${w}M" || echo "${w}.${f}M"
  elif [ "$n" -ge 1000 ]; then
    echo "$(( (n + 500) / 1000 ))k"
  else
    echo "$n"
  fi
}

# Whole seconds as 02h 03m 39s (a day or more: 5d 10h 12m 08s). Hours, minutes and seconds are
# always zero-padded so the width stays steady while it ticks.
fmt_hms() {
  local s="$1"; [ -z "$s" ] && return
  local d=$(( s / 86400 )) h=$(( s % 86400 / 3600 )) m=$(( s % 3600 / 60 )) sec=$(( s % 60 ))
  if [ "$d" -gt 0 ]; then printf '%dd %02dh %02dm %02ds' "$d" "$h" "$m" "$sec"
  else printf '%02dh %02dm %02ds' "$h" "$m" "$sec"
  fi
}

# Time until a Unix epoch, as fmt_hms. Nothing if already past.
fmt_until_hms() {
  local t="$1"; [ -z "$t" ] && return
  local s=$(( t - now )); [ "$s" -le 0 ] && return
  fmt_hms "$s"
}

# Same, minutes and seconds only (58m 12s). Cache lifetimes top out at 1h, so no hours.
fmt_until_ms() {
  local t="$1"; [ -z "$t" ] && return
  local s=$(( t - now )); [ "$s" -le 0 ] && return
  printf '%02dm %02ds' $(( s / 60 )) $(( s % 60 ))
}

# Color for a "how full" percentage: green < 50, yellow < 80, red otherwise
level_color() {
  local p="${1:-0}"
  if   [ "$p" -ge 80 ]; then printf '%s' "$RED"
  elif [ "$p" -ge 50 ]; then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"
  fi
}

# Pacing ceiling: the max usage% you should have reached by now for even
# consumption across the full period. Args: resets_at, unit_secs, total_units
pace_ceiling() {
  local resets_at="$1" unit_secs="$2" total_units="$3"
  [ -z "$resets_at" ] && return
  local left=$(( resets_at - now )); [ "$left" -le 0 ] && return
  local elapsed=$(( unit_secs * total_units - left )); [ "$elapsed" -lt 0 ] && elapsed=0
  local ceiling=$(( (elapsed / unit_secs + 1) * 100 / total_units ))
  [ "$ceiling" -gt 100 ] && ceiling=100
  echo "$ceiling"
}

# Color for used% against its pacing ceiling: green, yellow at 71%+ of it, red at/over it
pace_color() {
  local used="${1:-0}" ceiling="$2"
  [ -z "$ceiling" ] && { printf '%s' "$WHITE"; return; }
  local ratio=$(( used * 100 / ceiling ))
  if   [ "$ratio" -ge 100 ]; then printf '%s' "$RED"
  elif [ "$ratio" -ge 71 ];  then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"
  fi
}

# Display width of a string, ignoring color codes (emoji count as 2).
vw() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g' | wc -L; }

# Pad a string with spaces to a display width.
pad() { local n=$(( $2 - $(vw "$1") )); [ "$n" -lt 0 ] && n=0; printf '%s%*s' "$1" "$n" ''; }

# Join non-empty arguments with a separator.
join_by() { local sep="$1"; shift; local out="" x; for x in "$@"; do [ -z "$x" ] && continue; out+="${out:+$sep}$x"; done; printf '%s' "$out"; }

# ---------------------------------------------------------------------------
# Pieces shown in the table
# ---------------------------------------------------------------------------
sid_short="${sid:0:8}"
cost_fmt=""; [ -n "$cost" ] && cost_fmt=$(printf '$%.2f' "$cost")

# Cost added by the most recent turn. The status line is stateless, so remember per session the
# cost when the current prompt began (= the last cost seen before prompt_id changed).
cost_delta_fmt=""
if [ -n "$sid" ] && [ -n "$cost" ]; then
  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/claude-statusline"
  state_file="$state_dir/$sid"
  st_prompt=""; st_start=""; st_last=""
  [ -r "$state_file" ] && read -r st_prompt st_start st_last < "$state_file"
  cur_prompt="${prompt_id:--}"
  if   [ -z "$st_prompt" ];              then turn_start="$cost"       # no baseline yet
  elif [ "$cur_prompt" != "$st_prompt" ]; then turn_start="${st_last:-$cost}"  # new turn began
  else                                        turn_start="$st_start"
  fi
  # A cost lower than the baseline means the session's cost was reset (/clear)
  awk -v c="$cost" -v b="$turn_start" 'BEGIN{exit !(c<b)}' && turn_start=0
  if [ "$cur_prompt $turn_start $cost" != "$st_prompt $st_start $st_last" ]; then
    mkdir -p "$state_dir" 2>/dev/null && printf '%s %s %s\n' "$cur_prompt" "$turn_start" "$cost" > "$state_file"
  fi
  cost_delta_fmt=$(awk -v c="$cost" -v b="$turn_start" 'BEGIN{d=c-b; if (d<0) d=0; printf "$%.2f", d}')
fi
dur_fmt=""; [ -n "$dur_ms" ] && dur_fmt=$(fmt_hms $(( dur_ms / 1000 )))
style_txt=""; [ -n "$style" ] && [ "$style" != "default" ] && style_txt="${GRAY}style${RST} ${style}"

ctx_c=$(level_color "${ctx_used:-0}")
five_ceil=$(pace_ceiling "$five_reset" 3600 5)
seven_ceil=$(pace_ceiling "$seven_reset" 86400 7)
five_c=$(pace_color "$five_pct" "$five_ceil")
seven_c=$(pace_color "$seven_pct" "$seven_ceil")
five_in=$(fmt_until_hms "$five_reset")
seven_in=$(fmt_until_hms "$seven_reset")

# Context: 61% 612k/1000k · 39% left · 2k out
fmt_k() { [ -n "$1" ] && echo "$(( ($1 + 500) / 1000 ))k"; }
ctx_amount=""
[ -n "$ctx_used" ] && ctx_amount="${ctx_used}% $(fmt_k "${in_tok:-0}")/$(fmt_k "${ctx_size:-0}")"
ctx_txt=""
if [ -n "$ctx_used" ]; then
  ctx_txt="${ctx_c}${ctx_amount}${RST}${GRAY} · ${ctx_rem}% left${RST}"
fi

# Current time, ticks with refreshInterval
clock_txt="$(date +%F) · $(date +%H:%M:%S) $(date +%:z)"

# Rate limits: 5h 72% 2h14m
# Each limit: used% (pace allowance) time until reset, e.g. 4% (≤60%) 2h 38m. The used% and allowance share one color.
five_txt="";  [ -n "$five_pct" ]  && five_txt="${five_c}${five_pct}%${five_ceil:+ (≤${five_ceil}%)}${RST}${GRAY}${five_in:+ · ${five_in}}${RST}"
seven_txt=""; [ -n "$seven_pct" ] && seven_txt="${seven_c}${seven_pct}%${seven_ceil:+ (≤${seven_ceil}%)}${RST}${GRAY}${seven_in:+ · ${seven_in}}${RST}"

# Prompt cache: warm · 93% hit · 58m 12s (cold: blue, recache tokens in place of the hit rate, time since it went cold)
# Hit rate color: under 50 red, 50-94 yellow, 95+ green.
hit_color() {
  if   [ "$1" -ge 95 ]; then printf '%s' "$GREEN"
  elif [ "$1" -ge 50 ]; then printf '%s' "$YELLOW"
  else printf '%s' "$RED"
  fi
}
pc_exp_in=$(fmt_until_ms "$pc_exp")
cache_txt=""
if [ "$pc_obs" = "true" ]; then
  D="${GRAY} · ${RST}"
  if [ "$pc_warm" = "true" ]; then cache_txt="${GREEN}warm${RST}"; else cache_txt="${BLUE}cold${RST}"; fi
  # A cold cache shows what it would cost to rebuild in the hit-rate slot.
  if [ "$pc_warm" != "true" ] && [ -n "$pc_recache" ]; then cache_txt+="${D}${YELLOW}recache $(fmt_tok "$pc_recache")${RST}"
  elif [ -n "$pc_hit" ]; then cache_txt+="${D}$(hit_color "$pc_hit")${pc_hit}% hit${RST}"
  else cache_txt+="${D}- hit"; fi
  # Warm: time until it goes cold. Cold: time since it went cold (from expires_at), or "-" if unknown.
  if [ "$pc_warm" = "true" ]; then cache_txt+="${D}${GRAY}${pc_exp_in:--}${RST}"
  else
    cold_for=""; [ "${pc_exp:-0}" -gt 0 ] && [ "$now" -gt "$pc_exp" ] && cold_for=$(fmt_hms $(( now - pc_exp )))
    cache_txt+="${D}${GRAY}${cold_for:--}${RST}"
  fi
elif [ -n "$pc" ]; then
  cache_txt="${GRAY}not observed${RST}"
fi

# Where: full launch path, then full cwd when different, branch, worktrees
git_branch=""
if [ -n "$cwd" ]; then
  git_branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ "$git_branch" = "HEAD" ] && git_branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi
where_txt="dir ${proj:-${cwd:--}}"
cwd_txt=""
if [ -n "$cwd" ] && { [ -n "$git_wt" ] || { [ -n "$proj" ] && [ "$cwd" != "$proj" ]; }; }; then
  cwd_txt="cwd ${cwd}"
fi
[ -n "$git_branch" ] && where_txt+="${GRAY} · ${RST}${BLUE}⎇ ${git_branch}${RST}"
[ -n "$git_wt" ]     && cwd_txt+="${GRAY} · ${RST}${BLUE}⌥ ${git_wt}${RST}"
[ -n "$wt_name" ]    && where_txt+="${GRAY} · ${RST}${BLUE}◆ ${wt_name}${RST}"

session_txt="${sname:-${GRAY}unnamed${RST}}"
cost_txt="${cost_fmt:+${GREEN}${cost_fmt}${RST}}${cost_delta_fmt:+ ${GREEN}(+${cost_delta_fmt})${RST}}"

# ---------------------------------------------------------------------------
# table: two label/value column pairs inside a rounded box.
# ---------------------------------------------------------------------------
design_table() {
  local V=() V2=()
  # Thinking shows only while on; fast mode always shows its brackets: [💡] · [⚡]
  local think_flag="" fast_flag=""
  [ "$thinking" = "true" ] && think_flag="[💡]"
  # Fast mode keeps its brackets when off (two spaces = one emoji wide, so the line doesn't shift)
  if [ "$fast" = "true" ]; then fast_flag="[⚡]"; else fast_flag="${GRAY}[  ]${RST}"; fi
  V+=("$(join_by "${GRAY} · ${RST}" "${model:--}" "${effort:--}" "$think_flag" "$fast_flag")")
  # Null/absent values (session start, after /compact) show "-"
  local ctx_line
  if [ -n "$ctx_txt" ]; then ctx_line="$ctx_txt"
  else ctx_line="${GRAY}- $(fmt_k "${in_tok:-0}")/$(fmt_k "${ctx_size:-0}") · - left${RST}"; fi
  V+=("ctx ${ctx_line}")
  V+=("5h ${five_txt:--}")
  V+=("7d ${seven_txt:--}")

  V2+=("$clock_txt")
  V2+=("${dur_fmt:--} · ${cost_txt:--}")
  V2+=("cache ${cache_txt:--}")
  tokd() { if [ -n "$1" ]; then fmt_tok "$1"; else printf '%s' -; fi; }
  V2+=("cache w/r $(tokd "$cu_cw")/$(tokd "$cu_cr") · out $(tokd "$cu_out")")
  if [ -n "$style_txt" ]; then V2+=("$style_txt"); fi
  local sess_txt; sess_txt=$(join_by "${GRAY} · ${RST}" "${GRAY}$([ -n "$ver" ] && echo "v$ver" || echo -)${RST}" "${GRAY}${sid_short:--}${RST}" "$session_txt")

  local rows=${#V[@]}; [ ${#V2[@]} -gt "$rows" ] && rows=${#V2[@]}
  local w1=0 w2=0 i x
  for x in "${V[@]}";  do (( $(vw "$x") > w1 )) && w1=$(vw "$x"); done
  for x in "${V2[@]}"; do (( $(vw "$x") > w2 )) && w2=$(vw "$x"); done
  # The paths span the full width in their own rows; widen the right column if they need more.
  local wall=$(( w1 + w2 + 3 )) need
  need=$(vw "$where_txt"); (( $(vw "$sess_txt") > need )) && need=$(vw "$sess_txt"); (( $(vw "$cwd_txt") > need )) && need=$(vw "$cwd_txt")
  (( need > wall )) && w2=$(( w2 + need - wall ))
  wall=$(( w1 + w2 + 3 ))

  dash() { printf '─%.0s' $(seq 1 "$1"); }
  local B="${BORDER}│${RST}"
  printf '%s╭%s┬%s╮%s\n' "$BORDER" "$(dash $((w1+2)))" "$(dash $((w2+2)))" "$RST"
  for (( i = 0; i < rows; i++ )); do
    printf '%s %s %s %s %s\n' "$B" "$(pad "${V[i]:-}" $w1)" "$B" "$(pad "${V2[i]:-}" $w2)" "$B"
  done
  printf '%s├%s┴%s┤%s\n' "$BORDER" "$(dash $((w1+2)))" "$(dash $((w2+2)))" "$RST"
  printf '%s %s %s\n' "$B" "$(pad "$sess_txt" "$wall")" "$B"
  printf '%s %s %s\n' "$B" "$(pad "$where_txt" "$wall")" "$B"
  [ -n "$cwd_txt" ] && printf '%s %s %s\n' "$B" "$(pad "$cwd_txt" "$wall")" "$B"
  printf '%s╰%s╯%s' "$BORDER" "$(dash $(( wall + 2 )))" "$RST"
}

printf '%s' "$WHITE"
design_table
printf '\033[0m'
