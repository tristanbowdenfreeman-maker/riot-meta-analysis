-- Lane matchups grouped by the opponent's class. Single champion pairs are too
-- small at this sample size (a typical pair has under 10 games); six classes give each
-- champion a full list with enough games per row to read. pick_share is how often the champion
-- faced that class in lane.
CREATE OR ALTER VIEW mart.v_champion_class_matchups
AS
WITH faced AS (
    SELECT m.patch,
           a.champion_id,
           a.team_position                                      AS role,
           ISNULL(c.primary_class, 'Unknown')                   AS opponent_class,
           COUNT(*)                                             AS games,
           SUM(CAST(a.win AS INT))                              AS wins
    FROM mart.v_valid_match AS m
    JOIN fact.match_participant AS a ON a.match_id = m.match_id
    JOIN fact.match_participant AS b
      ON b.match_id = a.match_id
     AND b.team_position = a.team_position
     AND b.team_id <> a.team_id
    LEFT JOIN dim.champion AS c ON c.champion_id = b.champion_id
    WHERE a.team_position IS NOT NULL
    GROUP BY m.patch, a.champion_id, a.team_position, c.primary_class
)
SELECT f.patch, f.champion_id, f.role, f.opponent_class, f.games, f.wins,
       CAST(f.wins AS FLOAT) / f.games                                                    AS win_rate,
       CAST(f.games AS FLOAT) / SUM(f.games) OVER (PARTITION BY f.patch, f.champion_id, f.role) AS pick_share
FROM faced AS f;
GO
