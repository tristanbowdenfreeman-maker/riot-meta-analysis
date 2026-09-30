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
- **Valid match**: a ranked solo/duo match lasting at least 5 minutes. Shorter games are
  **remakes** and are left out of every statistic.
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
  the order they were bought in, which would need the timeline endpoint.
- **Keystone**: the first rune in the primary rune tree.

## Layers

| Schema | Holds | Written by |
|---|---|---|
| `stg` | Raw API responses and the fetch queue | Python |
| `dim` | Champion, item, rune and spell names from Data Dragon | `etl.usp_load_ddragon` |
| `fact` | Matches, player records, items, runes and bans parsed from the raw JSON | `etl.usp_load_matches` |
| `mart` | Reporting views, one per dashboard table | Views over `fact` and `dim` |
| `etl` | Procedures and data-quality checks | |

## Known limits

- Players are sampled from the first pages of each division's ladder, not uniformly from the whole
  division, and each division gets the same number of pages. Higher divisions are therefore
  over-represented compared with the real player base.
- Sample tier is one label per match, not each player's own rank.
- Item stats come from the final inventory, so they favour items bought in longer games.
- Win rates on small samples are noisy; the dashboard hides rows below a minimum-games cutoff
  (50 games at 3,000 matches, raised at 30,000).
