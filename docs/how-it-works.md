# How it works

The definitions behind the numbers, and why I built it the way I did.

## Scope

| | |
|---|---|
| Server | EUW |
| Queue | Ranked solo/duo only (queue 420) |
| Ranks | Emerald and above ("Emerald+") |
| Patch | One at a time. It goes live at 30,000 matches and keeps growing up to a cap |

Players are found on the ranked ladder and visited in a random (seeded) order. Only a set number
of matches is taken from each player per visit (`--per-player`, 20 in `scripts/collect.sh`), so no
single player dominates the sample.

## Why BigQuery, and where the JSON lives

The model and every stat on the site are BigQuery SQL; the marts are a dbt project (`dbt/`). It runs on the free sandbox, which needs no
billing account but allows no DML (`INSERT`, `UPDATE`, `DELETE`, `MERGE`) and expires tables after
60 days. So:

- Rows go in with **load jobs**, which are free and append whole batches.
- Rows come out by **rebuilding the table without them** (`CREATE OR REPLACE TABLE ... AS SELECT`).
- Each build pushes every table's expiry back, so the fact tables never lapse.
- Every query has a cap on the bytes it may scan (`BQ_MAX_GB_BILLED`), so a mistake fails instead
  of using up the free 1 TB a month. The marts are rebuilt once a day, which scans a few GB.

The raw JSON stays on the laptop, in a SQLite store (`data/riot.sqlite`), gzipped exactly as the
API returned it, with the download queue and the patch table. Python parses it
(`src/riot_meta/parse.py`) and loads the rows. Keeping the raw JSON means I can change the model
and reload it without calling the API again.

Every load is incremental: only matches not loaded yet are picked up, 2,000 at a time. BigQuery
can't load several tables in one transaction, so each batch is written down in the store first; if
a run stops half-way, the next one takes that batch back out of BigQuery and loads it again.

## One patch at a time

The store's `patch` table (copied to `riot_etl.patch`) tracks which patch the site shows (`live`) and which is being filled (`collecting`).

1. Each round, `python -m riot_meta patch` checks Data Dragon for a new patch. A new one is added
   as `collecting`, and only games played since then are queued.
2. The collector queues games until the patch has `MATCHES_PER_PATCH` valid matches,
   then stops and checks for a new patch every hour. `HOLD_PATCH` keeps
   it on one patch instead, taking only games played before the next patch started.
3. The site keeps showing the old patch: `riot_mart.valid_match` only lets the live patch through, so
   every mart ignores the new one until it's ready.
4. Once the new patch reaches 30,000 (`MATCHES_TO_GO_LIVE`), it goes live and the old patch's fact
   rows are rebuilt out of BigQuery, then its raw JSON is deleted from the store.

So the store and BigQuery never hold more than two patches, and the site never shows a patch on a handful
of games. If another patch comes out before the new one is full, the
unfinished one is dropped and collection moves on.

## Running on a laptop

- No database server runs locally: the store is one SQLite file, and the heavy SQL runs in
  BigQuery.
- The collector runs at low CPU priority, and the Riot API rate limits (`RIOT_RATE_LIMITS`) set
  how fast it downloads, whatever the key.

## The tables

| Where | What's in it | Loaded by |
|---|---|---|
| SQLite store | Raw API responses, the download queue and the patch table | Python |
| `riot_dim` | Champion, item, rune and summoner spell names from Data Dragon | `ddragon.py` |
| `riot_fact` | Matches, player records, items, runes, bans, team objectives | `transform.py` (matches) |
| `riot_fact` | Shop events, gold at 10/15/20/25 minutes, skill order | `transform.py` (timelines) |
| `riot_mart` | One table per table on the website | dbt (`dbt/models/marts`), rebuilt by `build` |
| `riot_etl` | `patch`, copied from the store | `patches.py` |

The main fact table, `riot_fact.match_participant`, has one row per player per match (10 per match).

## Definitions

- **Valid match**: ranked solo/duo on EUW lasting at least 5 minutes. Shorter games are remakes
  and are left out everywhere (`riot_mart.valid_match`).
- **Patch**: the first two parts of the game version: `16.19.712.3456` is patch `16.19`.
- **Role**: Riot's `teamPosition`: TOP, JUNGLE, MIDDLE, BOTTOM or UTILITY (support).
- **Win rate**: wins / games for a champion in a role.
- **Pick rate**: a champion's games in a role / valid matches in the patch.
- **Ban rate**: matches where the champion was banned / valid matches.
- **Completed item**: costs 1,000+ gold and doesn't build into anything else. Boots are counted
  separately.
- **Margin of error**: 1.96 × √(p(1 − p) / games), the 95% range around a win rate. The site
  shows it as ±.

## Build order comes from the timeline

A match only lists the items held at the end. The order they were bought in comes from a second
API call per match, the timeline. `fact.item_event` keeps its purchases, sales and undos, and:

- `riot_mart.item_purchase` drops purchases that were undone.
- `riot_mart.completed_item_order` numbers each player's completed items 1st, 2nd, 3rd...
- **Starter items**: everything bought in the first 90 seconds, except the trinket.
- **Core items**: the three items most often finished 1st, 2nd or 3rd. Exact three-item orders
  split the games into too many small groups, so I count each item wherever it lands in the first
  three.
- **After the core**: every other finished item. It shows no win rate, because only longer games
  get that far.

Build tables only use matches whose timeline has loaded, so a missing timeline never looks like a
player who bought nothing.

## Ranking the tier list without small-sample luck

Ranking by raw win rate puts a 38–18 champion (68% over 56 games) above a 211–153 one (58% over
364). So the tier list uses an **adjusted win rate**: the champion's record plus `prior_games`
extra games at 50%.

    adjusted = (wins + prior_games / 2) / (games + prior_games)

`prior_games` is estimated from the data each time (empirical Bayes):

1. The spread of win rates between champions is partly real and partly chance.
2. The chance part is known: p(1 − p) / games on average.
3. Observed variance − chance variance = real variance.
4. `prior_games = 0.25 / real variance`.

At 3,000 matches this came to about 255 games, so the 38–18 record counts as 53.2% while the
211–153 record only falls to 54.7%. It's worked out again on every build, and the site shows the
current value.

Tiers are cut by rank within each role (OP = top 5%, then 1 to 5). A champion needs a 1%+ pick
rate in the role, and the role must be 10%+ of its games, to get a tier.

**Counter picks** use the same idea on a smaller scale: an opponent needs 5+ games, and is ranked
by `(wins + 10 × the champion's overall win rate) / (games + 10)`.

## Insights

- **Winners vs losers**: each stat's average for winners divided by losers', minus 1, per role.
- **Bans**: win rate of champions grouped by how often they're banned.
- **Objectives**: the win rate of the team that took each objective first, and by how many it took.
- **Gold leads**: the leading team's win rate at 10, 15, 20 and 25 minutes, by size of lead; and
  when one laner is 1,000+ gold ahead of their opponent.

These show what winning teams have in common. They don't prove what causes the win, because the
better team tends to get the objectives, kills and gold as well.

## Data checks

`sql/3_checks` is one query with a row per check (every match has 10 players, exactly one winning team,
no objective taken first by both teams, and so on). `python -m riot_meta check` fails if a
blocking check fails, and the collector only publishes when they all pass.

Before that, `dbt build` tests every mart as it builds it (`dbt/models/marts/_marts.yml`): its key
columns are never null and never repeat, win rates, pick rates and shares lie between 0 and 1,
and the tier list's margin of error is at most 0.98 (1.96 × √0.25). A failed test stops the
build, so a broken mart never reaches the export.

## Known limits

- Players come from the first pages of each division's ladder, so higher divisions are
  over-represented.
- The API doesn't give each player's rank inside a match. A match is labelled with the rank of the
  player it was sampled from.
- Some items are never bought directly because another item turns into them (Seraph's Embrace,
  Muramana, Fimbulwinter). Build order shows the item that was bought.
- Win rates on small samples are noisy. The site hides options with fewer than 1 game per 300
  matches (minimum 10).
