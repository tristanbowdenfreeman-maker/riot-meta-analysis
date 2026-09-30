#!/usr/bin/env bash
# Publish the website to the portfolio: copy site/ into the tiny-summit repo's league/ folder,
# commit it there and push, so https://tristanbowdenfreeman-maker.github.io/tiny-summit/league/
# updates a minute or so later. Does nothing if the site hasn't changed since the last publish.
#
#   scripts/publish.sh
#   PORTFOLIO=~/elsewhere/tiny-summit scripts/publish.sh

set -euo pipefail
cd "$(dirname "$0")/.."

PORTFOLIO=${PORTFOLIO:-$HOME/Projects/tiny-summit}
[ -d "$PORTFOLIO/.git" ] || { echo "publish: no git repo at $PORTFOLIO" >&2; exit 1; }

rsync -a --delete --exclude .DS_Store site/ "$PORTFOLIO/league/"

cd "$PORTFOLIO"
git add league
if git diff --cached --quiet -- league; then
  echo "publish: the League page is already up to date"
  exit 0
fi
matches=$(python3 -c 'import json, sys; print(f"{json.load(open(sys.argv[1]))[0][\"matches\"]:,}")' league/data/patch_summary.json)
git commit -q -m "Refresh League statistics: $matches matches" -- league
git pull -q --rebase --autostash
git push -q
echo "publish: pushed $matches matches to the portfolio"
