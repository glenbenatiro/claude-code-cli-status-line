#!/usr/bin/env bash
# Preview the status line against the sample payloads in fixtures/.
#   ./preview.sh                 all fixtures
#   ./preview.sh full            one fixture
#   PLAIN=1 ./preview.sh         strip colors
cd "$(dirname "$0")"
fixtures="${*:-real-session full early windows}"
now=$(date +%s)
# Previews must not touch the real per-session cost state or the shared rate-limit file.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

for f in $fixtures; do
  # Each fixture gets its own empty state, so one fixture's shared rate limits don't show in the next.
  export XDG_STATE_HOME="$tmp/$f/state" CLAUDE_CONFIG_DIR="$tmp/$f/config"; mkdir -p "$XDG_STATE_HOME" "$CLAUDE_CONFIG_DIR"
  if [ -n "$PLAIN" ]; then printf "── %s ──\n" "$f"; else printf "\033[1;37m── %s ──\033[0m\n" "$f"; fi
  # Move timestamps to fixed offsets from now so countdowns look realistic.
  jq --argjson now "$now" '
    if .rate_limits.five_hour then .rate_limits.five_hour.resets_at = $now + 8040 else . end
    | if .rate_limits.seven_day then .rate_limits.seven_day.resets_at = $now + 460800 else . end
    | if .prompt_cache then .prompt_cache.expires_at = $now + 3480 else . end
  ' "fixtures/$f.json" \
    | bash statusline.sh \
    | if [ -n "$PLAIN" ]; then sed 's/\x1b\[[0-9;]*m//g'; else cat; fi
  printf '\n\n'
done
