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
# Pacing, so a faster Riot key never means a harder-working Mac:
#   - At most $MAX_PER_HOUR matches an hour, however fast the key allows: a round of $STEP
#     matches takes at least STEP / MAX_PER_HOUR hours, resting if it finished early.
#   - The site data is re-exported at most every $EXPORT_EVERY minutes (the slowest stage).
#   - Before each round and each heavy stage it waits while the Mac is busy (5-minute load
#     average over $MAX_LOAD), short of memory (under $MIN_FREE_MEM% free) or disk (under
#     $MIN_FREE_GB GB), or on battery below $MIN_BATTERY%. These trip well before the Mac gets
#     hot; macOS's own thermal warning is only a last resort.
#   - The database is capped at 2 CPUs and 3 GB of memory (docker-compose.yml).
#
#   scripts/collect.sh                                            # in the foreground
#   nohup caffeinate -i scripts/collect.sh >> collect.log 2>&1 &  # in the background
#   STEP=500 scripts/collect.sh

set -uo pipefail
cd "$(dirname "$0")/.."

STEP=${STEP:-1000}
PAGES=${PAGES:-2}            # ladder pages per division already discovered
PER_PLAYER=${PER_PLAYER:-20} # newest matches taken from each player per visit
MAX_PER_HOUR=${MAX_PER_HOUR:-1500}  # matches an hour at most
EXPORT_EVERY=${EXPORT_EVERY:-60}    # minutes between site exports at least
MAX_LOAD=${MAX_LOAD:-6}             # pause above this 5-minute load average (8 cores)
MIN_FREE_MEM=${MIN_FREE_MEM:-20}    # pause below this much free memory (%)
MIN_FREE_GB=${MIN_FREE_GB:-25}      # pause below this much free disk
MIN_BATTERY=${MIN_BATTERY:-40}      # pause on battery below this charge (%)
REST=${REST:-120}                   # seconds between rounds at least
LAST_EXPORT=0
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

free_gb() { df -g / | awk 'NR == 2 { print $4 }'; }
on_low_battery() {
  pmset -g batt | grep -q "Battery Power" || return 1
  [ "$(pmset -g batt | grep -o '[0-9]*%' | tr -d %)" -lt "$MIN_BATTERY" ]
}
# macOS prints "No thermal warning level has been recorded" unless the Mac is running hot.
running_hot() { pmset -g therm | grep -i "warning level" | grep -viq "no .*warning level"; }
# 5-minute load average as a whole number, and the share of memory free.
load5() { sysctl -n vm.loadavg | awk '{ printf "%d", $3 }'; }
free_mem() { memory_pressure | awk -F': ' '/free percentage/ { print $2 + 0 }'; }

# Wait until the Mac has disk space, power and is not running hot.
wait_until_safe() {
  while true; do
    if [ "$(free_gb)" -lt "$MIN_FREE_GB" ]; then
      stamp "Only $(free_gb) GB of disk free (minimum $MIN_FREE_GB GB). Paused; checking every 30 minutes."
      sleep 1800
    elif on_low_battery; then
      stamp "On battery below $MIN_BATTERY%. Paused until the Mac is charging; checking every 10 minutes."
      sleep 600
    elif [ "$(load5)" -ge "$MAX_LOAD" ]; then
      stamp "The Mac is busy (load $(load5), limit $MAX_LOAD). Paused for 5 minutes."
      sleep 300
    elif [ "$(free_mem)" -lt "$MIN_FREE_MEM" ]; then
      stamp "Only $(free_mem)% of memory free (minimum $MIN_FREE_MEM%). Paused for 5 minutes."
      sleep 300
    elif running_hot; then
      stamp "macOS reports a thermal warning. Paused for 15 minutes to cool down."
      sleep 900
    else
      return
    fi
  done
}

while true; do
  wait_until_safe
  ROUND_START=$(date +%s)
  run patch || { wait_after_failure; continue; }
  stamp "Queueing up to $STEP more matches"
  run queue --more "$STEP" --per-player "$PER_PLAYER" || { wait_after_failure; continue; }
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
  wait_until_safe
  run transform || { wait_after_failure; continue; }
  run patch || { wait_after_failure; continue; }   # goes live once the new patch is full
  if [ $(( $(date +%s) - LAST_EXPORT )) -lt $(( EXPORT_EVERY * 60 )) ]; then
    stamp "Exported less than $EXPORT_EVERY minutes ago; the site updates after a later round."
  elif run check; then
    wait_until_safe
    if run export >/dev/null; then
      LAST_EXPORT=$(date +%s)
      stamp "Exported site/data"
      scripts/publish.sh || stamp "Publishing to the portfolio failed; it will retry next round."
    fi
  else
    stamp "A blocking data check failed, so site/data was not updated. Collection carries on."
  fi
  run status
  # Keep to MAX_PER_HOUR: a round of STEP matches takes at least this long.
  wait=$(( STEP * 3600 / MAX_PER_HOUR - ($(date +%s) - ROUND_START) ))
  [ "$wait" -gt "$REST" ] && stamp "Pacing to $MAX_PER_HOUR matches an hour: resting $((wait / 60)) minutes."
  sleep $(( wait > REST ? wait : REST ))
done
