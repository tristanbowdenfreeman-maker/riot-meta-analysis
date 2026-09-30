# 7. Fetch match timelines for build order

**Status:** accepted, 2026-09-30. Supersedes [0005](0005-final-inventory-not-build-order.md).

## Context

The site follows op.gg's champion page: starter items, first boots, core build (first three
completed items in order) and the 4th/5th/6th item. None of these can come from the final
inventory: starters are sold by the end, and the inventory has no order. Purchase order is only
in the match timeline, one more API call per match.

## Decision

Add a fourth fetch stage, `fetch-timelines`, which downloads the timeline of every fetched match
into `stg.timeline_raw` (GZIP-compressed like the matches, ~57 KB each). `etl.usp_load_timelines`
keeps only the shop events (`ITEM_PURCHASED`, `ITEM_SOLD`, `ITEM_UNDO`) in `fact.item_event`.
Views then:

- drop purchases that were undone (`mart.v_item_purchase`),
- number each player's completed items by first purchase (`mart.v_completed_item_order`),
- build starter sets, first boots, core builds and item slots from those.

## Consequences

- Fetch time doubles: ~1 more hour at 3,000 matches on a development key, ~10 more hours at 30,000.
- ~1.7 GB of compressed timelines at 30,000 matches.
- Build-order views only count matches whose timeline loaded (`fact.match_timeline`), so a
  missing timeline never looks like a player who bought nothing.
- The final-inventory item stats (`mart.v_champion_item_stats`) stay; the item-pairs view they
  replaced is gone.
