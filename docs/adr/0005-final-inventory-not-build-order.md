# 5. Item stats from final inventory, not build order

**Status:** accepted, 2026-09-30

## Context

The match endpoint returns each player's final inventory. Purchase order is only in the timeline
endpoint, which would cost a second API call per match and double the fetch time on a
development key (100 requests every 2 minutes).

## Decision

Version 1 uses final inventory only: item win rates, build rates and pairs of completed items
finished together (`mart.v_champion_item_pairs`), the nearest thing to a "core build".

## Consequences

- Fetching stays at one call per match.
- No "first item" or build-path stats yet. Adding timelines later means a new staging table and
  a second fetch stage; nothing already built has to change.
