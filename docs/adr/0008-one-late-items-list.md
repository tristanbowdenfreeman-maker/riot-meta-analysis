# 8. One late-items list instead of 4th, 5th and 6th item

**Status:** accepted, 2026-09-30. Amends [0007](0007-timelines-for-build-order.md).

## Context

The champion page copied op.gg's separate 4th, 5th and 6th item lists. With the 3,000-match
sample and the 10-game minimum, those lists were empty on most ranked champion pages:

| List | Empty on ranked pages (of 219) |
|---|---|
| 4th item | 146 |
| 5th item | 199 |
| 6th item | 216 |
| 4th to 6th, one list | 127 |

Games on this patch average 28 minutes, so few players finish a 5th or 6th item. Scaling the
sample by ten (30,000 matches) with a 30-game minimum would still leave the 6th-item list empty
on 202 of 219 pages. Three lists also repeat the same few items in each column.

## Decision

Replace `mart.v_champion_item_slots` with `mart.v_champion_late_items`: one row per item built
4th, 5th or 6th. `pick_share` there is the share of players who reached a 4th item that built it
in any of those slots, shown on the site as "Built by". A player can build up to three late
items, so the shares add up to between 1 and 3, which a site-data test checks.

## Consequences

- The late-items list shows data on 92 more ranked pages at 3,000 matches.
- The site no longer says when an item is usually built (4th vs 6th), only that it is a late item.
