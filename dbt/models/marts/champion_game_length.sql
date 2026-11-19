-- Which champions win short games and which win long ones, all roles together. Short games end
-- before 25 minutes and long games last 33+ (about the shortest and longest quarter of games).
-- swing = long-game win rate minus short-game win rate: + means the champion gets stronger as
-- the game goes on. Champions need 300+ games in both lengths.
WITH game AS (
    SELECT m.patch, p.champion_id, CAST(p.win AS INT64) AS win,
           CASE WHEN m.duration_s < 1500 THEN 'short' WHEN m.duration_s >= 1980 THEN 'long' END AS length
    FROM {{ ref('valid_match') }} AS m
    JOIN {{ ref('stg_fact_match_participant') }} AS p ON p.match_id = m.match_id
),
champion AS (
    SELECT patch, champion_id,
           COUNT(*)                             AS games,
           SUM(win)                             AS wins,
           COUNTIF(length = 'short')            AS short_games,
           SUM(IF(length = 'short', win, 0))    AS short_wins,
           COUNTIF(length = 'long')             AS long_games,
           SUM(IF(length = 'long', win, 0))     AS long_wins
    FROM game
    GROUP BY patch, champion_id
),
match_length AS (
    SELECT patch,
           AVG(IF(duration_s < 1500, 1.0, 0))   AS short_match_share,
           AVG(IF(duration_s >= 1980, 1.0, 0))  AS long_match_share
    FROM {{ ref('valid_match') }}
    GROUP BY patch
)
SELECT c.patch, c.champion_id, d.champion_name, c.games,
       c.wins / c.games                                         AS win_rate,
       c.short_games, c.short_wins,
       c.short_wins / c.short_games                             AS short_win_rate,
       c.long_games, c.long_wins,
       c.long_wins / c.long_games                               AS long_win_rate,
       c.long_wins / c.long_games - c.short_wins / c.short_games AS swing,
       1.96 * SQRT(0.25 / c.short_games + 0.25 / c.long_games)  AS swing_moe,
       l.short_match_share, l.long_match_share
FROM champion AS c
JOIN match_length AS l ON l.patch = c.patch
JOIN {{ ref('stg_dim_champion') }} AS d ON d.champion_id = c.champion_id
WHERE c.short_games >= 300 AND c.long_games >= 300
