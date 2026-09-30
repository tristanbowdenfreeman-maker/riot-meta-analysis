-- Win rate by how many of an objective a team took (capped, e.g. "4+ dragons"). Kills are left
-- out: a kill count says more about game length than about the objective.
CREATE OR ALTER VIEW mart.v_objective_count_win_rate
AS
SELECT t.patch,
       o.objective,
       c.taken,
       c.is_capped,
       COUNT(*)                                      AS games,
       SUM(t.win)                                    AS wins,
       CAST(SUM(t.win) AS FLOAT) / COUNT(*)          AS win_rate,
       1.96 * SQRT(0.25 / COUNT(*))                  AS win_rate_moe
FROM mart.v_team_result AS t
JOIN fact.team_objective AS o ON o.match_id = t.match_id AND o.team_id = t.team_id
CROSS APPLY (SELECT CASE o.objective WHEN 'dragon' THEN 4 WHEN 'horde' THEN 3 WHEN 'tower' THEN 9
                                     WHEN 'inhibitor' THEN 3 ELSE 2 END AS cap) AS k
CROSS APPLY (SELECT IIF(o.kills >= k.cap, k.cap, o.kills) AS taken,
                    IIF(o.kills >= k.cap, 1, 0)            AS is_capped) AS c
WHERE o.objective <> 'champion'
GROUP BY t.patch, o.objective, c.taken, c.is_capped;
GO
