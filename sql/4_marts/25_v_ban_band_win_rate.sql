-- Win rate of champions grouped by how often they are banned. win_rate_moe is the 95% margin
-- of error (games are player records, so it slightly understates it for champions who often
-- meet themselves in a match; that's rare).
CREATE OR ALTER VIEW mart.v_ban_band_win_rate
AS
SELECT b.patch,
       band.band_order,
       band.band,
       COUNT(*)                                          AS champions,
       SUM(b.games)                                      AS games,
       SUM(b.wins)                                       AS wins,
       CAST(SUM(b.wins) AS FLOAT) / SUM(b.games)         AS win_rate,
       1.96 * SQRT(0.25 / SUM(b.games))                  AS win_rate_moe
FROM mart.v_ban_vs_win AS b
CROSS APPLY (SELECT CASE WHEN b.ban_rate >= 0.10 THEN 1 WHEN b.ban_rate >= 0.03 THEN 2 ELSE 3 END AS band_order,
                    CASE WHEN b.ban_rate >= 0.10 THEN 'Banned in 10%+ of games'
                         WHEN b.ban_rate >= 0.03 THEN 'Banned in 3-10%'
                         ELSE 'Banned in under 3%' END AS band) AS band
GROUP BY b.patch, band.band_order, band.band;
GO
