#!/usr/bin/env bash
# Check how sessions share the 5h and 7d limits through the shared rate-limit file, and that bad input
# never breaks the status line. Each step runs statusline.sh as one session, then checks what it shows
# and what the shared file holds. It uses temporary state and config directories, so it never touches
# the real files.
#   ./test.sh
cd "$(dirname "$0")"
tmp=$(mktemp -d); trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
export XDG_STATE_HOME="$tmp/state" CLAUDE_CONFIG_DIR="$tmp/config"
mkdir -p "$CLAUDE_CONFIG_DIR"
shared="$CLAUDE_CONFIG_DIR/statusline-rate-limits.json"
now=$(date +%s)
R=$(( now + 200000 )) R_EARLY=$(( now + 50000 )) R5=$(( now + 8000 ))
fails=0

# run <session> <cost> [rate_limits JSON] -> OUT (the status line, colors stripped). Any stderr fails.
run() {
  OUT=$(printf '{"session_id":"%s","prompt_id":"p1","model":{"id":"m"},"cost":{"total_cost_usd":%s},"rate_limits":%s}' "$1" "$2" "${3:-null}" \
    | bash statusline.sh 2>"$tmp/err" | sed 's/\x1b\[[0-9;]*m//g')
  if [ -s "$tmp/err" ]; then echo "FAIL  stderr from session $1: $(head -c 300 "$tmp/err")"; fails=$(( fails + 1 )); fi
}
# Payloads: seven <pct> [resets_at], five <pct> [resets_at], both <5h pct> <7d pct>
seven() { printf '{"seven_day":{"used_percentage":%s,"resets_at":%s}}' "$1" "${2:-$R}"; }
five()  { printf '{"five_hour":{"used_percentage":%s,"resets_at":%s}}' "$1" "${2:-$R5}"; }
both()  { printf '{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}' "$1" "$R5" "$2" "$R"; }
# What the status line shows for a limit: "7d 3%" or "7d -"
shown() { [[ "$OUT" =~ ($1\ [0-9]+%|$1\ -) ]] && echo "${BASH_REMATCH[1]}" || echo "nothing"; }
# A value from the shared file: the value, "none" if absent, "missing" without a file, "invalid" if not JSON
fget() { [ -e "$shared" ] || { echo missing; return; }; jq -r "$1 | if . == null then \"none\" else tostring end" "$shared" 2>/dev/null || echo invalid; }
# check <description> <actual> <expected>
check() {
  if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fails=$(( fails + 1 )); fi
}
# A shared file entry: entry <key> <pct> <resets_at> <observed_at> <session>
entry() { printf '"%s": {"used_percentage": %s, "resets_at": %s, "observed_at": %s, "session_id": "%s"}' "$@"; }

echo "-- sharing"
run old 5.00 "$(seven 99)"
check "an idle session shows its own reading"                         "$(shown 7d)" "7d 99%"
check "an idle session never writes, even when there is no file"      "$(fget .)" "missing"
run new 0
run new 0.30 "$(seven 3)"
check "a session that just heard from the API shows its reading"      "$(shown 7d)" "7d 3%"
check "and writes it to the file"                                     "$(fget .seven_day.used_percentage)" "3"
check "the file has version 1"                                        "$(fget .version)" "1"
check "the file names the session that reported it"                   "$(fget .seven_day.session_id)" "new"
obs=$(fget .seven_day.observed_at)
check "the file records when it was observed"                         "$(( obs >= now && obs <= now + 30 ))" "1"
check "the file is private (mode 600)"                                "$(stat -c %a "$shared" 2>/dev/null || stat -f %Lp "$shared" 2>/dev/null)" "600"
run old 5.00 "$(seven 99)"
check "after a usage reset, an idle session shows the new reading"    "$(shown 7d)" "7d 3%"
check "and leaves the file alone"                                     "$(fget .seven_day.used_percentage)" "3"
run new 0.55 "$(seven 4)"
check "usage climbs in the active session"                            "$(fget .seven_day.used_percentage)" "4"
run new 0.70 "$(seven 1 "$R_EARLY")"
run old 5.00 "$(seven 99)"
check "a reset that moves the window end earlier still wins"          "$(shown 7d)" "7d 1%"

echo "-- when a session counts as fresh"
run third 0
run third 1.00 "$(seven 7 "$R_EARLY")"
run new 0.10 "$(seven 1 "$R_EARLY")"
check "a cost that went down is not fresh"                            "$(fget .seven_day.used_percentage)" "7"
check "so that session shows the file"                                "$(shown 7d)" "7d 7%"
run new 0.10 "$(seven 9 "$R_EARLY")"
check "a reading that changed without a cost change is fresh (429)"   "$(fget .seven_day.used_percentage)" "9"
run new 0.20 "$(five 12)"
check "a 5h-only reading is written"                                  "$(fget .five_hour.used_percentage)" "12"
check "and keeps the 7d entry"                                        "$(fget .seven_day.used_percentage)" "9"
run drop 0
run drop 0.50 "$(both 10 20)"
run new 0.25 "$(seven 25)"
run drop 0.50 "$(seven 20)"
check "a window that drops out of a reading is not fresh"             "$(fget .seven_day.used_percentage)" "25"

echo "-- observed_at"
printf '{"version": 1, %s}\n' "$(entry seven_day 25 "$R" $(( now - 30 )) other)" > "$shared"
run new 0.30 "$(seven 25)"
check "a recently confirmed reading is not rewritten"                 "$(fget .seven_day.observed_at)" "$(( now - 30 ))"
printf '{"version": 1, %s}\n' "$(entry seven_day 25 "$R" $(( now - 120 )) other)" > "$shared"
run new 0.35 "$(seven 25)"
check "a reading not confirmed for a minute gets a new observed_at"   "$(fget .seven_day.session_id)" "new"

echo "-- expired and unusable files"
printf '{"version": 1, %s}\n' "$(entry seven_day 40 $(( now - 10 )) $(( now - 100 )) other)" > "$shared"
before=$(cat "$shared")
run old 5.00 "$(seven 99)"
check "an expired entry falls back to the session's own reading"      "$(shown 7d)" "7d 99%"
check "without writing"                                               "$(cat "$shared")" "$before"
printf 'garbage{' > "$shared"
run old 5.00 "$(seven 99)"
check "a corrupt file is ignored"                                     "$(shown 7d)" "7d 99%"
check "and the rest of the line still renders"                        "$([[ "$OUT" == *"╰"* && "$OUT" == *"m ·"* ]] && echo yes)" "yes"
run new 0.40 "$(seven 26)"
check "a fresh session replaces a corrupt file"                       "$(fget .seven_day.used_percentage)" "26"
{ printf '{"version": 1, %s, "pad": "' "$(entry seven_day 50 "$R" "$now" other)"; head -c 9000 /dev/zero | tr '\0' 'x'; printf '"}\n'; } > "$shared"
run old 5.00 "$(seven 99)"
check "an oversized file is ignored"                                  "$(shown 7d)" "7d 99%"
run new 0.45 "$(seven 27)"
check "and replaced by the next fresh session"                        "$(fget .seven_day.used_percentage)" "27"
printf '{"version": 1, "seven_day": {"used_percentage": "x", "resets_at": %s, "observed_at": %s, "session_id": "other"}}\n' "$R" "$now" > "$shared"
run old 5.00 "$(seven 99)"
check "a non-number in the file is ignored"                           "$(shown 7d)" "7d 99%"
printf '{"version": 2, %s}\n' "$(entry seven_day 50 "$R" "$now" other)" > "$shared"
before=$(cat "$shared")
run new 0.50 "$(seven 28)"
check "a file from a newer version is ignored"                        "$(shown 7d)" "7d 28%"
check "and never overwritten"                                         "$(cat "$shared")" "$before"
rm -f "$shared"
printf '{"session_id":"bad","model":{"id":"m"},"cost":{"total_cost_usd":"x"},"context_window":{"used_percentage":1e20}}' | bash statusline.sh >"$tmp/out" 2>"$tmp/err"
check "non-numbers and huge numbers in the payload don't break it"    "$(sed 's/\x1b\[[0-9;]*m//g' "$tmp/out" | grep -c '^│ m · ')$(wc -c < "$tmp/err" | tr -d ' ')" "10"

echo "-- upgrades"
printf 'five 99 %s\nseven 99 %s\n' "$R5" "$R" > "$CLAUDE_CONFIG_DIR/statusline-rate-limits"
run fourth 0
check "the old text file is removed"                                  "$([ -e "$CLAUDE_CONFIG_DIR/statusline-rate-limits" ] && echo present || echo gone)" "gone"
check "and its values are not used"                                   "$(shown 7d)" "7d -"
mkdir -p "$XDG_STATE_HOME/claude-statusline"; printf 'p1 5000000 5000000\n' > "$XDG_STATE_HOME/claude-statusline/legacy"
run legacy 5.00 "$(seven 50)"
check "an old 3-field state file is not fresh"                        "$(fget .)" "missing"
run legacy 5.00 "$(seven 51)"
check "but the next changed reading is"                               "$(fget .seven_day.used_percentage)" "51"

echo "-- writing"
chmod 500 "$CLAUDE_CONFIG_DIR"
run legacy 5.10 "$(seven 52)"
chmod 700 "$CLAUDE_CONFIG_DIR"
check "a read-only config dir gives no write and no error"            "$(fget .seven_day.used_percentage)" "51"
run legacy 5.10 "$(seven 52)"
check "and the session doesn't retry every second"                    "$(fget .seven_day.used_percentage)" "51"
for i in $(seq 20 39); do run "par$i" 0; done
for i in $(seq 20 39); do printf '{"session_id":"par%s","cost":{"total_cost_usd":1},"rate_limits":%s}' "$i" "$(seven "$i")" | bash statusline.sh >/dev/null 2>&1 & done; wait
p=$(fget .seven_day.used_percentage)
check "20 sessions writing at once leave a valid file"                "$(( p >= 20 && p <= 39 ))" "1"
check "and no temp files"                                             "$(ls "$CLAUDE_CONFIG_DIR" | grep -c tmp)" "0"
touch -d '40 days ago' "$XDG_STATE_HOME/claude-statusline/ancient" 2>/dev/null || touch -t "$(date -v-40d +%Y%m%d%H%M)" "$XDG_STATE_HOME/claude-statusline/ancient"
touch -d '2 hours ago' "$shared.tmp.1" 2>/dev/null || touch -t "$(date -v-2H +%Y%m%d%H%M)" "$shared.tmp.1"
touch "$shared.tmp.2"
run brandnew 0
check "a new session prunes state files untouched for 30 days"        "$([ -e "$XDG_STATE_HOME/claude-statusline/ancient" ] && echo kept || echo pruned)" "pruned"
check "and temp files older than an hour"                             "$([ -e "$shared.tmp.1" ] && echo kept || echo pruned)$([ -e "$shared.tmp.2" ] && echo kept || echo pruned)" "prunedkept"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
