-- Blue side against red side. Every match has one winner, so the two win rates add up to 1.
SELECT m.patch,
       IF(p.team_id = 100, 'Blue', 'Red')                                  AS side,
       COUNT(DISTINCT m.match_id)                                          AS games,
       COUNT(DISTINCT IF(p.win, m.match_id, NULL))                         AS wins,
       COUNT(DISTINCT IF(p.win, m.match_id, NULL)) / COUNT(DISTINCT m.match_id) AS win_rate,
       1.96 * SQRT(0.25 / COUNT(DISTINCT m.match_id))                      AS win_rate_moe
FROM {{ ref('valid_match') }} AS m
JOIN {{ ref('stg_fact_match_participant') }} AS p ON p.match_id = m.match_id
GROUP BY m.patch, p.team_id
