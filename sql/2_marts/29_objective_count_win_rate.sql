-- Win rate by how many of an objective a team took (capped, e.g. "4+ dragons"). Kills are left
-- out: a kill count says more about game length than about the objective.
CREATE OR REPLACE TABLE riot_mart.objective_count_win_rate AS
WITH capped AS (
    SELECT t.patch, t.win, o.objective, o.kills,
           CASE o.objective WHEN 'dragon' THEN 4 WHEN 'horde' THEN 3 WHEN 'tower' THEN 9
                            WHEN 'inhibitor' THEN 3 ELSE 2 END AS cap
    FROM riot_mart.team_result AS t
    JOIN riot_fact.team_objective AS o ON o.match_id = t.match_id AND o.team_id = t.team_id
    WHERE o.objective <> 'champion'
)
SELECT patch,
       objective,
       LEAST(kills, cap)                AS taken,
       IF(kills >= cap, 1, 0)           AS is_capped,
       COUNT(*)                         AS games,
       SUM(win)                         AS wins,
       SUM(win) / COUNT(*)              AS win_rate,
       1.96 * SQRT(0.25 / COUNT(*))     AS win_rate_moe
FROM capped
GROUP BY patch, objective, taken, is_capped;
