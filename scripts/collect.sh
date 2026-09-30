#!/usr/bin/env bash
# Keep growing the sample, one round of $STEP matches at a time, until stopped.
#
# Each round queues more EUW matches (finding more players once the known ones run out),
# downloads them and their timelines, loads them into the fact tables, runs the data checks and,
# if they pass, re-exports site/data. Every stage resumes where it stopped, so the script can be
# killed and restarted at any time. When the Riot key expires it waits and retries every
# 5 minutes: put a new key in .env and it carries on.
#
#   scripts/collect.sh                                         # in the foreground
#   nohup caffeinate -i scripts/collect.sh > collect.log 2>&1 &   # in the background
#   STEP=500 SINCE=2026-09-24 scripts/collect.sh

set -uo pipefail
cd "$(dirname "$0")/.."

SINCE=${SINCE:-2026-09-24}   # patch 26.19 (game version 16.19) release
STEP=${STEP:-1000}
PAGES=${PAGES:-2}            # ladder pages per division already discovered
LOG=$(mktemp)

stamp() { printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M')" "$*"; }

# Run one pipeline command, keeping its output in $LOG as well as on screen.
run() { .venv/bin/python -u -m riot_meta "$@" 2>&1 | tee "$LOG"; return "${PIPESTATUS[0]}"; }

# Why the last command failed: wait for a new key, or wait out a network or database blip.
wait_after_failure() {
  if grep -q "RiotAuthError" "$LOG"; then
    stamp "The Riot key has expired. Put a new RIOT_API_KEY in .env; retrying every 5 minutes."
    sleep 300
  else
    stamp "That step failed (see above); retrying in 1 minute."
    sleep 60
  fi
}

while true; do
  stamp "Queueing $STEP more matches"
  run queue --since "$SINCE" --more "$STEP" || { wait_after_failure; continue; }
  if grep -q "ran out of players" "$LOG"; then
    PAGES=$((PAGES + 1))
    stamp "Every known player visited: discovering ladder page $PAGES of each division"
    run discover --pages "$PAGES" || { PAGES=$((PAGES - 1)); wait_after_failure; continue; }
    continue   # queue again, now with the new players
  fi

  run fetch || { wait_after_failure; continue; }
  run fetch-timelines || { wait_after_failure; continue; }
  run transform || { wait_after_failure; continue; }
  if run check; then
    run export >/dev/null && stamp "Exported site/data"
  else
    stamp "A blocking data check failed, so site/data was not updated. Collection carries on."
  fi
  run status
done
