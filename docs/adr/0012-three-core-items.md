# 12. Three core items, and everything else after the core

**Status:** accepted, 2026-09-30. Amends [0010](0010-fill-build-and-matchup-panels.md).

## Context

ADR 0010 listed every item finished 1st, 2nd or 3rd as "Core items", and items finished 4th or
later as "After the core".

- Core items ran to six or more rows, so it didn't read as a build.
- Only about a quarter of players finish a 4th item, so After the core was thin or empty on many
  pages.

## Decision

- **Core items** shows three cards: the three items finished 1st, 2nd or 3rd most often, with
  enough games to pass the site's minimum (16 at 4,949 matches).
  - They're ordered by the slot each usually takes, and labelled 1st, 2nd and 3rd item.
  - Each shows how often it's one of the first three, and its win rate.
- **After the core** lists every other finished item, wherever it was built.
  - It combines `mart.v_champion_core_items` and `mart.v_champion_late_items` on the site, so no
    new view was needed. `v_champion_late_items` gained `avg_slot`.
  - Its share is out of all the champion's games with a timeline, not just those reaching a 4th
    item.
  - It lists up to eight items built by at least 3 players, each with the slot it usually takes.
  - It still shows no win rate, because items finished later come from longer games.

## Consequences

- The build section reads as a path of three items, then the alternatives.
- After the core now includes situational swaps for a core item (e.g. Mikael's Blessing on
  Thresh), not just 4th-to-6th items, so it's rarely empty.
