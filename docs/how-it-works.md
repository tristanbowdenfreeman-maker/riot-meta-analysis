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

## Why SQL Server, and why the JSON is parsed in T-SQL

I wanted the modelling to be real T-SQL, the SQL most analyst jobs ask for. SQL Server has no Mac
version, so it runs in Docker (`docker-compose.yml`).

Python only downloads data. Each match is stored exactly as the API returned it (compressed) in
`stg.match_raw`, and stored procedures parse it with `OPENJSON` into the fact tables. Keeping the
raw JSON means I can change the model and rebuild it without calling the API again
(`EXEC etl.usp_reset_facts`, then `python -m riot_meta transform`).

Every load is incremental: a procedure only picks up matches that aren't in its table yet, in
batches that commit one at a time.

## One patch at a time

`etl.patch` tracks which patch the site shows (`live`) and which is being filled (`collecting`).

1. Each round, `python -m riot_meta patch` checks Data Dragon for a new patch. A new one is added
   as `collecting` (`etl.usp_start_patch`), and only games played since then are queued.
2. The collector queues games until the patch has `MATCHES_PER_PATCH` valid matches
   (`etl.v_patch_progress`), then stops and checks for a new patch every hour. `HOLD_PATCH` keeps
   it on one patch instead, taking only games played before the next patch started.
3. The site keeps showing the old patch: `mart.v_valid_match` only lets the live patch through, so
   every view ignores the new one until it's ready.
4. Once the new patch reaches 30,000 (`MATCHES_TO_GO_LIVE`), `etl.usp_promote_patch` makes it live and
   `etl.usp_delete_retired_patches` deletes the old patch's raw JSON and fact rows, 1,000 matches
   per transaction.

So the database never holds more than two patches, and the site never shows a patch on a handful
of games. If another patch comes out before the new one is full, the
unfinished one is dropped and collection moves on.

## Running on a laptop

- SQL Server runs in Docker capped at 2 CPU cores and 3 GB of memory (`docker-compose.yml`), and
  its cache at 2 GB (`sql/0_setup/03_server_settings.sql`).
- Simple recovery mode, so the transaction log is reused instead of growing forever.
- The collector runs at low CPU priority, and the Riot API rate limits (`RIOT_RATE_LIMITS`) set
  how fast it downloads, whatever the key.

## The tables

| Schema | What's in it | Loaded by |
|---|---|---|
| `stg` | Raw API responses and the download queue | Python |
| `dim` | Champion, item, rune and summoner spell names from Data Dragon | `etl.usp_load_ddragon` |
| `fact` | Matches, player records, items, runes, bans | `etl.usp_load_matches` |
| `fact` | Shop events from the timelines | `etl.usp_load_timelines` |
| `fact` | Team objectives; gold at 10/15/20/25 minutes | `etl.usp_load_objectives`, `etl.usp_load_frames` |
| `mart` | One view per table on the website | views |
| `etl` | The procedures above, the data checks, and `etl.patch` | |

The main fact table, `fact.match_participant`, has one row per player per match (10 per match).

## Definitions

- **Valid match**: ranked solo/duo on EUW lasting at least 5 minutes. Shorter games are remakes
  and are left out everywhere (`mart.v_valid_match`).
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

- `mart.v_item_purchase` drops purchases that were undone.
- `mart.v_completed_item_order` numbers each player's completed items 1st, 2nd, 3rd...
- **Starter items**: everything bought in the first 90 seconds, except the trinket.
- **Core items**: the three items most often finished 1st, 2nd or 3rd. Exact three-item orders
  split the games into too many small groups, so I count each item wherever it lands in the first
  three.
- **After the core**: every other finished item. It shows no win rate, because only longer games
  get that far.

Build views only use matches whose timeline has loaded, so a missing timeline never looks like a
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
211–153 record only falls to 54.7%. It's worked out again on every export, and the site shows the
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

`sql/5_checks` is one view with a row per check (every match has 10 players, exactly one winning team,
no objective taken first by both teams, and so on). `python -m riot_meta check` fails if a
blocking check fails, and the collector only publishes when they all pass.

## Known limits

- Players come from the first pages of each division's ladder, so higher divisions are
  over-represented.
- The API doesn't give each player's rank inside a match. A match is labelled with the rank of the
  player it was sampled from.
- Some items are never bought directly because another item turns into them (Seraph's Embrace,
  Muramana, Fimbulwinter). Build order shows the item that was bought.
- Win rates on small samples are noisy. The site hides options with fewer than 1 game per 300
  matches (minimum 10).
