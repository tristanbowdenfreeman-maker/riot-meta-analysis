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

# Version the script and stylesheet links, so browsers fetch the new files after each change
# instead of running a cached copy.
version=$(cat site/app.js site/styles.css | shasum | cut -c1-8)
sed -i '' -e "s|href=\"styles.css\"|href=\"styles.css?v=$version\"|" \
          -e "s|src=\"app.js\"|src=\"app.js?v=$version\"|" "$PORTFOLIO/league/index.html"

cd "$PORTFOLIO"
git add league
if git diff --cached --quiet -- league; then
  echo "publish: the League page is already up to date"
  exit 0
fi
matches=$(python3 -c 'import json, sys; print(format(json.load(open(sys.argv[1]))[0]["matches"], ","))' league/data/patch_summary.json)
git commit -q -m "Refresh League statistics: $matches matches" -- league
git pull -q --rebase --autostash
git push -q
echo "publish: pushed $matches matches to the portfolio"
