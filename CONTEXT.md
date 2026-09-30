# Context

What this project is, and what its terms mean. Decisions and their reasons are in [docs/adr](docs/adr).

## Purpose

A portfolio project for data analyst and BI roles. It answers one question for each League of
Legends patch: **which champions, items, runes and summoner spells are winning in Emerald+ solo/duo
on EUW?** It is built to be explained in an interview, so it prefers plain, well-known techniques
over clever ones.

## Scope

| | |
|---|---|
| Game | League of Legends |
| Server | EUW (`euw1` for league data, `europe` for match data) |
| Queue | Ranked solo/duo only (queue 420) |
| Ranks | Emerald, Diamond, Master, Grandmaster, Challenger ("Emerald+") |
| Patch | One patch at a time; every mart view is split by patch |
| Sample size | 3,000 matches for the first build, then 30,000 matches (300,000 player records) per patch |

## Terms

- **Match**: one game, identified by a match ID such as `EUW1_7123456789`.
- **Player record** (or participant): one player in one match, so every match has 10. This is the
  grain of `fact.match_participant`.
- **Patch**: the first two parts of the game version, e.g. game version `16.19.712.3456` is patch `16.19`.
- **Valid match**: a ranked solo/duo match on EUW lasting at least 5 minutes. Shorter games are
  **remakes** and are left out of every statistic. A player's match history also holds games on
  the other European servers (EUNE, TR, RU; about 1 in 200 matches); those are not queued and the
  valid-match view leaves them out.
- **Role**: Riot's `teamPosition`: TOP, JUNGLE, MIDDLE, BOTTOM or UTILITY (support).
- **Sample tier**: the tier of the player whose match history the match was taken from. The API
  does not report each player's rank inside a match, so this is the rank label for the whole match.
- **Win rate**: wins / games for a champion in a role.
- **Pick rate**: games for a champion in a role / valid matches in the patch.
- **Ban rate**: valid matches where the champion was banned / valid matches in the patch.
- **Role share**: the share of a champion's games played in a given role.
- **Completed item**: an item that does not build into anything else and costs at least 1,000 gold.
  **Boots** are counted separately. Components, starters, consumables and trinkets are ignored in
  the item stats.
- **Build rate**: the share of a champion's games (in that role) that ended with the item in the
  final inventory.
- **Final inventory**: the items held when the game ended (`item0`-`item6`). It says nothing about
  the order they were bought in; that comes from the timeline.
- **Timeline**: a second API response per match, minute by minute, with every shop event. Only
  purchases, sales and undos are kept (`fact.item_event`).
- **Purchase**: an `ITEM_PURCHASED` event that wasn't undone straight after.
- **Starter set**: everything bought in the first 90 seconds except the trinket, with quantities
  (e.g. Doran's Blade + 1 Health Potion).
- **First boots**: the first tier-2 boots bought.
- **Item number** (1st item, 2nd item...): completed items numbered in the order they were first
  bought. Boots are not counted.
- **Core build**: a player's 1st, 2nd and 3rd completed items, in that order.
- **Core items**: the three items a champion's players most often finish 1st, 2nd or 3rd, shown in
  the order they usually come. Shown on the site instead of exact core builds
  ([ADR 0010](docs/adr/0010-fill-build-and-matchup-panels.md),
  [ADR 0012](docs/adr/0012-three-core-items.md)).
- **After the core**: every other item the champion's players finish, at any point, as a share of
  all their games with a timeline ([ADR 0012](docs/adr/0012-three-core-items.md)).
- **Counter picks** ("Does best vs" / "Does worst vs"): lane opponents with 5+ games, ranked by
  win rate pulled towards the champion's own ([ADR 0013](docs/adr/0013-counter-picks.md)).
- **Headline figures**: the size of the data behind a patch (`mart.v_data_volume`): matches,
  player records, item events, rune choices, bans, fact rows and mart views
  ([ADR 0011](docs/adr/0011-dark-theme-and-insights-dashboard.md)).
- **Pick share**: within a champion and role, the share of games using that option (a rune, a
  starter set, a core build). For item numbers, it's the share of players who reached that number.
- **Keystone**: the first rune in the primary rune tree.
- **Stat shards**: the three small bonuses under the rune trees (offense, flex, defense rows).
- **Rune page**: a keystone plus a secondary tree. The rune grid and shards on the website are
  shown for each of a champion's two most played pages, out of that page's games.
- **Adjusted win rate**: (wins + prior_games / 2) / (games + prior_games). Adding prior_games games
  at 50% pulls small samples towards 50%, so a lucky 38-18 doesn't outrank a solid 211-153.
  prior_games is estimated from the data on every export (about 255 at 3,000 matches); see
  [ADR 0009](docs/adr/0009-estimate-the-tier-list-prior.md).
- **Margin of error**: 1.96 standard errors of a win rate, sqrt(p(1 - p) / games): the range
  that would hold the true win rate 95% of the time.
- **Winners vs losers gap**: the winners' average of a stat divided by the losers' average, minus
  1, per role (Insights page). It describes what winning looks like, not what causes it.
- **Team objective**: one team's record for one objective in a match (tower, inhibitor, dragon,
  void grubs, Rift Herald, Baron, champion kills): whether it took it first, and how many it took
  (`fact.team_objective`). "First blood" is the champion objective taken first
  ([ADR 0014](docs/adr/0014-objectives-and-gold-leads.md)).
- **Gold frame**: a player's total gold, XP and creep score at 10, 15, 20 or 25 minutes, from the
  timeline (`fact.participant_frame`).
- **Gold lead**: one team's total gold minus the other's at a minute mark. The lead band's win rate
  is the leading team's.
- **Lane lead**: a player 1,000+ gold ahead of the opponent in the same role at a minute mark.
- **Tier**: rank by adjusted win rate within a role, cut by percentile: OP (top 5%), 1 (next 15%),
  2 (next 25%), 3 (next 30%), 4 (next 17%), 5 (bottom 8%). Only champion/role pairs with a pick
  rate of at least 1% (30 games at 3,000 matches) that make up at least 10% of the champion's games get a tier.

## Layers

| Schema | Holds | Written by |
|---|---|---|
| `stg` | Raw API responses (matches, timelines) and the fetch queue | Python |
| `dim` | Champion, item, rune and spell names and icons from Data Dragon; stat shards | `etl.usp_load_ddragon` |
| `fact` | Matches, player records, items, runes and bans parsed from the raw JSON | `etl.usp_load_matches` |
| `fact` | Shop events parsed from the timelines | `etl.usp_load_timelines` |
| `fact` | Team objectives from the matches; gold frames from the timelines | `etl.usp_load_objectives`, `etl.usp_load_frames` |
| `mart` | Reporting views, one per table on the website | Views over `fact` and `dim` |
| `etl` | Procedures and data-quality checks | |

The website (`site/`) reads the `mart` views as JSON; see [ADR 0006](docs/adr/0006-static-site-instead-of-streamlit.md).

## Known limits

- Players are sampled from the first pages of each division's ladder, not uniformly from the whole
  division, and each division gets the same number of pages. Higher divisions are therefore
  over-represented compared with the real player base.
- Sample tier is one label per match, not each player's own rank.
- Final-inventory item stats favour items bought in longer games; the build-order views don't.
- Supports' starting World Atlas is granted by the game with no player attached
  (`participantId` 0). The starter-set view adds it for every support, which the timelines back
  up: each support later destroys a World Atlas under their own id when it upgrades.
- Some completed items are never bought because an earlier item turns into them: Seraph's
  Embrace, Muramana and Fimbulwinter (from Archangel's Staff, Manamune and Winter's Approach),
  Gunmetal Greaves (Berserker's Greaves' upgrade) and Diadem of Songs (the finished support quest).
  Build order shows the item that was bought.
- If a player buys the same item twice and then undoes both purchases, the first purchase is
  still counted. This only happens with consumables.
- Win rates on small samples are noisy. The website hides build, rune and matchup options with
  fewer than 1 game per 300 matches (minimum 10: 10 games at 3,000 matches, 100 at 30,000).
