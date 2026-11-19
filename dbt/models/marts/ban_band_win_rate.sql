-- Win rate of champions grouped by how often they are banned. win_rate_moe is the 95% margin
-- of error (games are player records, so it slightly understates it for champions who often
-- meet themselves in a match; that's rare).
WITH banded AS (
    SELECT b.*,
           CASE WHEN b.ban_rate >= 0.10 THEN 1 WHEN b.ban_rate >= 0.03 THEN 2 ELSE 3 END AS band_order,
           CASE WHEN b.ban_rate >= 0.10 THEN 'Banned in 10%+ of games'
                WHEN b.ban_rate >= 0.03 THEN 'Banned in 3-10%'
                ELSE 'Banned in under 3%' END AS band
    FROM {{ ref('ban_vs_win') }} AS b
)
SELECT patch,
       band_order,
       band,
       COUNT(*)                         AS champions,
       SUM(games)                       AS games,
       SUM(wins)                        AS wins,
       SUM(wins) / SUM(games)           AS win_rate,
       1.96 * SQRT(0.25 / SUM(games))   AS win_rate_moe
FROM banded
GROUP BY patch, band_order, band
