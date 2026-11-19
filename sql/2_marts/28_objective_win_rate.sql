-- What each objective is worth: how often the team that took it first went on to win, and how
-- often anyone took it at all. objective 'champion' is first blood.
CREATE OR REPLACE TABLE riot_mart.objective_win_rate AS
WITH loaded AS (
    SELECT t.patch, COUNT(DISTINCT t.match_id) AS matches
    FROM riot_mart.team_result AS t
    WHERE t.match_id IN (SELECT match_id FROM riot_fact.team_objective)
    GROUP BY t.patch
)
SELECT t.patch,
       o.objective,
       COUNT(*)                         AS games,
       SUM(t.win)                       AS wins,
       SUM(t.win) / COUNT(*)            AS win_rate,
       1.96 * SQRT(0.25 / COUNT(*))     AS win_rate_moe,
       COUNT(*) / MAX(l.matches)        AS taken_share
FROM riot_mart.team_result AS t
JOIN riot_fact.team_objective AS o ON o.match_id = t.match_id AND o.team_id = t.team_id AND o.is_first
JOIN loaded AS l ON l.patch = t.patch
GROUP BY t.patch, o.objective;
