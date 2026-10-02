-- Which dragon soul wins most: the win rate of the team that got each soul, how often each soul
-- was given out, and when. Out of valid matches whose timeline has loaded.
CREATE OR ALTER VIEW mart.v_dragon_soul_win_rate
AS
WITH loaded AS (
    SELECT t.patch, COUNT(DISTINCT t.match_id) AS matches
    FROM mart.v_team_result AS t
    JOIN fact.dragon_soul AS d ON d.match_id = t.match_id
    GROUP BY t.patch
)
SELECT t.patch,
       d.soul,
       COUNT(*)                                      AS games,
       SUM(t.win)                                    AS wins,
       CAST(SUM(t.win) AS FLOAT) / COUNT(*)          AS win_rate,
       1.96 * SQRT(0.25 / COUNT(*))                  AS win_rate_moe,
       CAST(COUNT(*) AS FLOAT) / MAX(l.matches)      AS soul_share,
       AVG(d.timestamp_ms / 60000.0)                 AS avg_minute
FROM mart.v_team_result AS t
JOIN fact.dragon_soul AS d ON d.match_id = t.match_id AND d.team_id = t.team_id
JOIN loaded AS l ON l.patch = t.patch
GROUP BY t.patch, d.soul;
GO
