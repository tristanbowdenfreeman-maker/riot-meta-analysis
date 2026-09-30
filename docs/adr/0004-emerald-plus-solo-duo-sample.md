# 4. Sample Emerald+ ranked solo/duo on EUW

**Status:** accepted, 2026-09-30

## Context

Meta stats need many games per champion. 3,000 matches is about 30,000 picks, roughly 175 per
champion, which is too thin to split across all ten tiers.

## Decision

Only ranked solo/duo (queue 420) on EUW, from players in Emerald and above, the same filter
public meta sites use by default. Players are visited in a seeded random order and at most
five matches are taken from each, so no single player dominates the sample.

## Consequences

- Results describe higher-rank play, not the whole player base.
- The stats are reproducible for a given seed and player pool.
- A rank-by-rank comparison would need a bigger sample and is out of scope for version 1.
