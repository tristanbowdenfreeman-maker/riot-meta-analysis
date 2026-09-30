# 10. Core items, after the core, and matchups by class

**Status:** accepted, 2026-09-30. Amends [0008](0008-one-late-items-list.md). Build panels amended by
[0012](0012-three-core-items.md); matchups replaced by [0013](0013-counter-picks.md).

## Context

At 3,957 matches, many ranked champion pages (222 in total) had empty build and matchup panels,
because each option needs 13+ games to show:

| Panel | Empty pages |
|---|---|
| First three items (exact order) | 101 |
| Built 4th to 6th | 127 |
| Weak against | 148 |
| Strong against | 152 |

- Exact three-item orders split a champion's games over dozens of combinations.
- Only about a quarter of players finish a 4th item in games that average 28 minutes: about 28
  players for a typical champion.
- A typical single lane matchup has under 10 games. Even Yone mid's most common opponent had
  only 17.
- The "First item" panel repeated the first column of "First three items".

## Decision

- **Core items** (`mart.v_champion_core_items`) replaces the first-item and three-item panels.
  - It lists items finished 1st, 2nd or 3rd, wherever they land, with the slot they usually take.
  - Its pick share is out of all the champion's games.
  - `v_champion_core_builds` stays in SQL for analysis but is not exported.
- **After the core** (`mart.v_champion_late_items`) now covers items finished 4th or later, not
  just 4th to 6th.
  - Its share is out of the players who reached a 4th item.
  - The site lists items built by at least 3 of those players.
  - It shows no win rate, because only longer games reach a 4th item, which skews it.
- **Matchups** are grouped by the lane opponent's class (`mart.v_champion_class_matchups`), next
  to the five opponents faced most.
  - Every row shows a ± margin of error.
  - The margin uses the widest case (a 50% win rate), so a 5-0 record doesn't show ±0.
  - The tier list's "Weak against" column keeps the 13-game minimum.

## Consequences

- Across the 222 ranked pages:
  - After the core is empty on 22.
  - Boots is empty on 1 (Yuumi, who rarely buys boots).
  - Nothing else is empty.
- The site no longer shows exact build orders. "Usually 1st/2nd" on each core item keeps a rough
  order.
- Most-faced win rates rest on 5–40 games, and their ± says so.
