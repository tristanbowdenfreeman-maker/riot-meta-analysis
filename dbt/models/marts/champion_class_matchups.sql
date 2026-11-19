-- Lane matchups grouped by the opponent's class. Single champion pairs are too
-- small at this sample size (a typical pair has under 10 games); six classes give each
-- champion a full list with enough games per row to read. pick_share is how often the champion
-- faced that class in lane.
WITH faced AS (
    SELECT m.patch,
           a.champion_id,
           a.team_position                      AS role,
           IFNULL(c.primary_class, 'Unknown')   AS opponent_class,
           COUNT(*)                             AS games,
           COUNTIF(a.win)                       AS wins
    FROM {{ ref('valid_match') }} AS m
    JOIN {{ ref('stg_fact_match_participant') }} AS a ON a.match_id = m.match_id
    JOIN {{ ref('stg_fact_match_participant') }} AS b
      ON b.match_id = a.match_id
     AND b.team_position = a.team_position
     AND b.team_id <> a.team_id
    LEFT JOIN {{ ref('stg_dim_champion') }} AS c ON c.champion_id = b.champion_id
    WHERE a.team_position IS NOT NULL
    GROUP BY m.patch, a.champion_id, a.team_position, opponent_class
)
SELECT f.patch, f.champion_id, f.role, f.opponent_class, f.games, f.wins,
       f.wins / f.games                                                        AS win_rate,
       f.games / SUM(f.games) OVER (PARTITION BY f.patch, f.champion_id, f.role) AS pick_share
FROM faced AS f
