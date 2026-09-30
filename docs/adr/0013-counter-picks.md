# 13. Counter picks instead of matchups by class

**Status:** accepted, 2026-09-30. Amends [0010](0010-fill-build-and-matchup-panels.md).

## Context

ADR 0010 grouped each champion's lane opponents by class, next to the five opponents faced most.
The class view was steady but not useful: nobody picks against "Tanks". Readers want counter
picks: which champions this one beats, and which beat it.

A single lane matchup is small. At 4,949 matches, a typical ranked champion has only four
opponents with 8+ games, so ranking by raw win rate would put 5-0 and 0-5 records on top.

## Decision

- The champion page shows **Does best vs** and **Does worst vs**: up to five lane opponents each.
- Opponents need 5+ games.
- They're ranked by win rate pulled towards the champion's own win rate, as if each had 10 more
  games at that rate: `(wins + 10 × overall) / (games + 10)`. This is the same idea as the tier
  list prior in [0009](0009-estimate-the-tier-list-prior.md), on a smaller scale.
- Best vs lists opponents ranked above the champion's overall rate, worst vs those below.
- Each row shows the raw win rate with its ± margin of error, and how often the opponent was faced.
- `mart.v_champion_class_matchups` stays in SQL for analysis but is no longer exported.
- The tier list's "Weak against" column is unchanged (the site's game minimum, raw win rate).

## Consequences

- At 4,949 matches, 14 of 220 ranked pages have no "best vs" row and 15 have no "worst vs" row.
  Both panels fill as the collector adds games.
- Margins are wide (often ±15–35 points), and the page says so.
