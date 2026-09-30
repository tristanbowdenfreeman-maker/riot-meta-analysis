-- What each objective is worth: how often the team that took it first went on to win, and how
-- often anyone took it at all. objective 'champion' is first blood.
CREATE OR ALTER VIEW mart.v_objective_win_rate
AS
WITH loaded AS (
    SELECT t.patch, COUNT(DISTINCT t.match_id) AS matches
    FROM mart.v_team_result AS t
    WHERE EXISTS (SELECT 1 FROM fact.team_objective AS o WHERE o.match_id = t.match_id)
    GROUP BY t.patch
)
SELECT t.patch,
       o.objective,
       COUNT(*)                                      AS games,
       SUM(t.win)                                    AS wins,
       CAST(SUM(t.win) AS FLOAT) / COUNT(*)          AS win_rate,
       1.96 * SQRT(0.25 / COUNT(*))                  AS win_rate_moe,
       CAST(COUNT(*) AS FLOAT) / MAX(l.matches)      AS taken_share
FROM mart.v_team_result AS t
JOIN fact.team_objective AS o ON o.match_id = t.match_id AND o.team_id = t.team_id AND o.is_first = 1
JOIN loaded AS l ON l.patch = t.patch
GROUP BY t.patch, o.objective;
GO
