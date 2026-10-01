#!/usr/bin/env bash
# Keep collecting the current patch, one round of up to $STEP matches at a time, until stopped.
#
# Each round:
#   1. `patch` checks Data Dragon for a new patch. A new patch is collected in the background
#      while the site keeps showing the current one.
#   2. Queues more EUW matches of the patch being collected, up to MATCHES_PER_PATCH (30,000 by
#      default, set in .env). Once the patch is full it just checks for a new patch every hour.
#   3. Downloads the matches and timelines, loads them into the fact tables, and runs `patch`
#      again: a new patch with a full sample goes live and the old patch's data is deleted.
#   4. Runs the data checks and, if they pass, re-exports site/data and publishes it to the
#      portfolio (scripts/publish.sh).
#
# Every stage resumes where it stopped, so the script can be killed and restarted at any time.
# When the Riot key expires it waits and retries every 5 minutes: put a new key in .env and it
# carries on. It runs at low priority (nice), so the laptop stays responsive.
#
#   scripts/collect.sh                                            # in the foreground
#   nohup caffeinate -i scripts/collect.sh >> collect.log 2>&1 &  # in the background
#   STEP=500 scripts/collect.sh

set -uo pipefail
cd "$(dirname "$0")/.."

STEP=${STEP:-1000}
PAGES=${PAGES:-2}            # ladder pages per division already discovered
LOG=$(mktemp)
renice -n 10 $$ >/dev/null   # low CPU priority for this script and everything it starts

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
  run patch || { wait_after_failure; continue; }
  stamp "Queueing up to $STEP more matches"
  run queue --more "$STEP" || { wait_after_failure; continue; }
  if grep -q "is full" "$LOG"; then
    stamp "This patch has its full sample. Checking for a new patch again in an hour."
    sleep 3600
    continue
  fi
  if grep -q "ran out of players" "$LOG"; then
    PAGES=$((PAGES + 1))
    stamp "Every known player visited: discovering ladder page $PAGES of each division"
    run discover --pages "$PAGES" || { PAGES=$((PAGES - 1)); wait_after_failure; continue; }
    continue   # queue again, now with the new players
  fi

  run fetch || { wait_after_failure; continue; }
  run fetch-timelines || { wait_after_failure; continue; }
  run transform || { wait_after_failure; continue; }
  run patch || { wait_after_failure; continue; }   # goes live once the new patch is full
  if run check; then
    if run export >/dev/null; then
      stamp "Exported site/data"
      scripts/publish.sh || stamp "Publishing to the portfolio failed; it will retry next round."
    fi
  else
    stamp "A blocking data check failed, so site/data was not updated. Collection carries on."
  fi
  run status
done
