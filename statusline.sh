#!/usr/bin/env bash
# Source of truth: https://github.com/glenbenatiro/claude-code-cli-status-line
# If you edit this file, please also update that repo.
input=$(cat)

# Context window
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
remaining_pct=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')

# Rate limits
five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_hour_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_day_resets=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# Model (strip leading "claude-" to keep it short)
model_id=$(echo "$input" | jq -r '.model.id // empty')
model_short="${model_id#claude-}"

# Effort level
effort=$(echo "$input" | jq -r '.effort.level // empty')

# Extended thinking
thinking_enabled=$(echo "$input" | jq -r '.thinking.enabled // empty')

# Current working directory (basename only)
cwd=$(echo "$input" | jq -r '.cwd // empty')
cwd_short=$(basename "$cwd")

# Claude Code version
cc_version=$(echo "$input" | jq -r '.version // empty')

# Pacing ceiling: the max usage% you should have reached by now for even
# consumption across the full period.
# Args: used_pct (float), resets_at (Unix epoch), unit_secs (int), total_units (int)
# Prints an integer ceiling%, or nothing when inputs are invalid/missing.
pace_ceiling() {
  local used_pct_float="$1"
  local resets_at="$2"
  local unit_secs="$3"
  local total_units="$4"
  [ -z "$used_pct_float" ] || [ -z "$resets_at" ] || [ -z "$unit_secs" ] || [ -z "$total_units" ] && return
  local now secs_remaining total_secs elapsed_secs elapsed_units ceiling
  now=$(date +%s)
  secs_remaining=$(( resets_at - now ))
  [ "$secs_remaining" -le 0 ] && return
  total_secs=$(( unit_secs * total_units ))
  elapsed_secs=$(( total_secs - secs_remaining ))
  [ "$elapsed_secs" -lt 0 ] && elapsed_secs=0
  elapsed_units=$(( elapsed_secs / unit_secs ))
  ceiling=$(( (elapsed_units + 1) * 100 / total_units ))
  [ "$ceiling" -gt 100 ] && ceiling=100
  [ "$ceiling" -lt 0 ] && ceiling=0
  echo "$ceiling"
}

# Format a Unix epoch as a compact countdown: 3d2h, 1h23m, or 42m.
# Prints nothing if the timestamp is empty or already in the past.
compact_countdown() {
  local resets_at="$1"
  [ -z "$resets_at" ] && return
  local now secs days hours mins
  now=$(date +%s)
  secs=$(( resets_at - now ))
  [ "$secs" -le 0 ] && return
  days=$(( secs / 86400 ))
  hours=$(( (secs % 86400) / 3600 ))
  mins=$(( (secs % 3600) / 60 ))
  if [ "$days" -gt 0 ]; then
    printf '%dd%dh' "$days" "$hours"
  elif [ "$hours" -gt 0 ]; then
    printf '%dh%dm' "$hours" "$mins"
  else
    printf '%dm' "$mins"
  fi
}

# ---------------------------------------------------------------------------
# Line 1: model · effort · thinking state
# ---------------------------------------------------------------------------
line1=()

[ -n "$model_short" ] && line1+=("$(printf '\033[00;34m[%s]\033[00m' "$model_short")")
[ -n "$effort" ]      && line1+=("$(printf '\033[00;36m[%s]\033[00m' "$effort")")

if [ "$thinking_enabled" = "true" ]; then
  line1+=("$(printf '\033[00;36m[thinking:on]\033[00m')")
else
  line1+=("$(printf '\033[00;36m[thinking:off]\033[00m')")
fi

# ---------------------------------------------------------------------------
# Line 2: context window · rate limits with pacing budget
# ---------------------------------------------------------------------------
line2=()

if [ -n "$used_pct" ] && [ -n "$remaining_pct" ] && [ -n "$ctx_size" ]; then
  ctx_size_k=$(( ctx_size / 1000 ))
  used_pct_int=$(printf '%.0f' "$used_pct")
  used_k=$(( (ctx_size * used_pct_int + 50000) / 100000 ))
  line2+=("$(printf '\033[00;33m[ctx: %.0f%% %dk/%dk]\033[00m' "$used_pct" "$used_k" "$ctx_size_k")")
fi

if [ -n "$five_hour_pct" ] || [ -n "$seven_day_pct" ]; then
  rate_str=""

  # ANSI color constants for pacing ceiling indicator
  MAGENTA=$'\033[00;35m' GREEN=$'\033[00;32m' YELLOW=$'\033[00;33m' RED=$'\033[00;31m'

  if [ -n "$five_hour_pct" ]; then
    five_used_int=$(printf '%.0f' "$five_hour_pct")
    five_actual="${five_used_int}%"
    five_ceiling=$(pace_ceiling "$five_hour_pct" "$five_hour_resets" 3600 5)
    five_cd=$(compact_countdown "$five_hour_resets")
    if [ -n "$five_ceiling" ]; then
      ratio=$(( five_used_int * 100 / five_ceiling ))
      if   [ "$ratio" -ge 100 ]; then ceil_color="$RED"
      elif [ "$ratio" -ge 71  ]; then ceil_color="$YELLOW"
      else                             ceil_color="$GREEN"
      fi
      five_seg="5h: used ${five_actual} · ${ceil_color}≤${five_ceiling}% max${MAGENTA}"
    else
      five_seg="5h: used ${five_actual}"
    fi
    [ -n "$five_cd" ] && five_seg="$five_seg in $five_cd"
    rate_str="$five_seg"
  fi

  if [ -n "$seven_day_pct" ]; then
    seven_used_int=$(printf '%.0f' "$seven_day_pct")
    seven_actual="${seven_used_int}%"
    seven_ceiling=$(pace_ceiling "$seven_day_pct" "$seven_day_resets" 86400 7)
    seven_cd=$(compact_countdown "$seven_day_resets")
    if [ -n "$seven_ceiling" ]; then
      ratio=$(( seven_used_int * 100 / seven_ceiling ))
      if   [ "$ratio" -ge 100 ]; then ceil_color="$RED"
      elif [ "$ratio" -ge 71  ]; then ceil_color="$YELLOW"
      else                             ceil_color="$GREEN"
      fi
      seven_seg="7d: used ${seven_actual} · ${ceil_color}≤${seven_ceiling}% max${MAGENTA}"
    else
      seven_seg="7d: used ${seven_actual}"
    fi
    [ -n "$seven_cd" ] && seven_seg="$seven_seg in $seven_cd"
    rate_str="${rate_str:+$rate_str | }$seven_seg"
  fi

  line2+=("$(printf '\033[00;35m[%s]\033[00m' "$rate_str")")
fi

# ---------------------------------------------------------------------------
# Line 3: version · cwd (version is rightmost so it clips first on narrow terminals)
# ---------------------------------------------------------------------------
line3=()

[ -n "$cc_version" ] && line3+=("$(printf '\033[00;34m[v%s]\033[00m' "$cc_version")")
[ -n "$cwd_short" ]  && line3+=("$(printf '\033[00;32m[%s]\033[00m' "$cwd_short")")

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
printf '%s\n' "${line1[*]}"
printf '%s\n' "${line2[*]}"
printf '%s'   "${line3[*]}"
