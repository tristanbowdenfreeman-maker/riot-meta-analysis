# 9. Estimate the tier-list prior from the data

**Status:** accepted, 2026-09-30. Changes the adjusted win rate in [CONTEXT.md](../../CONTEXT.md).

## Context

The tier list ranked champions by (wins + 50) / (games + 100): a fixed 100-game prior at 50%.
At 3,000 matches the top of the list was still small samples. Zyra jungle ranked first on
38-18 (67.9% over 56 games, ±12.2 points).

How strong the prior should be depends on how much champions really differ. The observed
variance of win rates between ranked champion/role pairs (0.00406) is the real variance plus
sampling noise. The average noise is p(1 - p) / games (0.00309), so the real variance is about
0.00098, or 3.1 points either side of 50%. For a binomial record with a beta prior, the prior is
worth 0.25 / real variance games: about 255, not 100.

## Decision

`mart.v_tier_list` estimates `prior_games` on every export (empirical Bayes, method of moments):
0.25 / (VAR(win_rate) - AVG(win_rate * (1 - win_rate) / games)) over the ranked pairs of the
patch, with the real variance floored at 0.0001 so the prior can't exceed 2,500 games. The
adjusted win rate becomes (wins + prior_games / 2) / (games + prior_games).

The view also returns `win_rate_moe`, the 95% margin of error of the raw win rate, which the site
shows next to every win rate. The Insights page explains the method with a raw-against-adjusted chart of the top ten ([0011](0011-dark-theme-and-insights-dashboard.md)).

## Consequences

- At 3,000 matches the tier list is led by large samples: Janna support (58.0% over 364 games),
  Wukong jungle and Sett top. Zyra jungle's 67.9% counts as 53.2%.
- The prior shrinks by itself as the sample grows and the noise term gets smaller.
- One prior covers every role; about 40 ranked pairs per role is too few to estimate one each.
