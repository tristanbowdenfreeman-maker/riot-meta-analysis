-- Each champion's win rate by rank, per role. The rank is the tier of the player whose match history
-- the game came from (fact.match.sample_tier); matchmaking keeps the other nine close to it.
-- Master, Grandmaster and Challenger are grouped as Master+, since the top two hold few games.
-- pick_rate = share of the rank's matches with the champion in that role.
CREATE OR ALTER VIEW mart.v_champion_rank_win_rate
AS
WITH ranked AS (
    SELECT m.match_id, m.patch,
           CASE WHEN m.sample_tier IN ('MASTER', 'GRANDMASTER', 'CHALLENGER') THEN 'MASTER+' ELSE m.sample_tier END AS rank_band
    FROM mart.v_valid_match AS m
    WHERE m.sample_tier IS NOT NULL
),
band AS (
    SELECT patch, rank_band, COUNT(*) AS matches
    FROM ranked
    GROUP BY patch, rank_band
)
SELECT r.patch,
       p.champion_id,
       p.team_position                                          AS role,
       r.rank_band,
       COUNT(*)                                                 AS games,
       SUM(CAST(p.win AS INT))                                  AS wins,
       CAST(SUM(CAST(p.win AS INT)) AS FLOAT) / COUNT(*)        AS win_rate,
       CAST(COUNT(*) AS FLOAT) / MAX(b.matches)                 AS pick_rate
FROM ranked AS r
JOIN band AS b ON b.patch = r.patch AND b.rank_band = r.rank_band
JOIN fact.match_participant AS p ON p.match_id = r.match_id
WHERE p.team_position IS NOT NULL
GROUP BY r.patch, p.champion_id, p.team_position, r.rank_band;
GO
