-- Lane matchups: each player against the enemy in the same role.
SELECT m.patch,
       a.champion_id,
       a.team_position                  AS role,
       b.champion_id                    AS opponent_id,
       c.champion_name                  AS opponent_name,
       COUNT(*)                         AS games,
       COUNTIF(a.win)                   AS wins,
       COUNTIF(a.win) / COUNT(*)        AS win_rate
FROM {{ ref('valid_match') }} AS m
JOIN {{ ref('stg_fact_match_participant') }} AS a ON a.match_id = m.match_id
JOIN {{ ref('stg_fact_match_participant') }} AS b
  ON b.match_id = a.match_id
 AND b.team_position = a.team_position
 AND b.team_id <> a.team_id
LEFT JOIN {{ ref('stg_dim_champion') }} AS c ON c.champion_id = b.champion_id
WHERE a.team_position IS NOT NULL
GROUP BY m.patch, a.champion_id, a.team_position, b.champion_id, c.champion_name
