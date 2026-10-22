#!/usr/bin/env bash
# Check how sessions share the 7d limit through the shared rate-limit file.
#   ./test.sh
# Each step runs statusline.sh once as one session, then checks the 7d cell and the shared file.
# It uses temporary state and config directories, so it never touches the real files.
cd "$(dirname "$0")"
export XDG_STATE_HOME=$(mktemp -d) CLAUDE_CONFIG_DIR=$(mktemp -d); trap 'rm -rf "$XDG_STATE_HOME" "$CLAUDE_CONFIG_DIR"' EXIT
now=$(date +%s)
reset=$(( now + 200000 )) next_reset=$(( now + 200000 + 604800 ))
fails=0

# step <description> <session> <cost> <7d used %> <expected 7d %> [7d resets_at]
# An empty used % sends no rate limits, like a session before its first API response.
step() {
  local desc="$1" sid="$2" cost="$3" pct="$4" want="$5" r="${6:-$reset}" rl=null got file
  [ -n "$pct" ] && rl="{\"seven_day\":{\"used_percentage\":$pct,\"resets_at\":$r}}"
  got=$(printf '{"session_id":"%s","prompt_id":"p1","cost":{"total_cost_usd":%s},"rate_limits":%s}' "$sid" "$cost" "$rl" \
    | bash statusline.sh | sed 's/\x1b\[[0-9;]*m//g' | grep -o '7d [0-9]*%')
  file=$(grep '^seven ' "$CLAUDE_CONFIG_DIR/statusline-rate-limits" 2>/dev/null | cut -d' ' -f2)
  if [ "$got" = "7d $want%" ] && [ "$file" = "$want" ]; then
    echo "ok    $desc"
  else
    echo "FAIL  $desc: shows '${got:-nothing}', file has '${file:-nothing}', want $want%"
    fails=$(( fails + 1 ))
  fi
}

step "a session shares what it knows"                              old  5.00  99  99
step "the same session, idle, keeps it"                            old  5.00  99  99
step "a new session shows the shared value before any response"    new  0     ""  99
step "after a usage reset, a session that just heard wins"         new  0.30  2   2
step "an idle session from before the reset does not overwrite it" old  5.00  99  2
step "usage climbs in the active session"                          new  0.55  3   3
step "a later window wins, even from a session that is idle"       next 1.00  1   1  "$next_reset"
step "a session still on the earlier window does not overwrite it" new  0.80  4   1

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
