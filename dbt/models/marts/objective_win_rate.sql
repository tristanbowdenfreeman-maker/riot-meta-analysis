-- What each objective is worth: how often the team that took it first went on to win, and how
-- often anyone took it at all. objective 'champion' is first blood.
WITH loaded AS (
    SELECT t.patch, COUNT(DISTINCT t.match_id) AS matches
    FROM {{ ref('team_result') }} AS t
    WHERE t.match_id IN (SELECT match_id FROM {{ ref('stg_fact_team_objective') }})
    GROUP BY t.patch
)
SELECT t.patch,
       o.objective,
       COUNT(*)                         AS games,
       SUM(t.win)                       AS wins,
       SUM(t.win) / COUNT(*)            AS win_rate,
       1.96 * SQRT(0.25 / COUNT(*))     AS win_rate_moe,
       COUNT(*) / MAX(l.matches)        AS taken_share
FROM {{ ref('team_result') }} AS t
JOIN {{ ref('stg_fact_team_objective') }} AS o ON o.match_id = t.match_id AND o.team_id = t.team_id AND o.is_first
JOIN loaded AS l ON l.patch = t.patch
GROUP BY t.patch, o.objective
