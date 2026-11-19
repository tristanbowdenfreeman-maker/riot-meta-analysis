-- Each champion's win rate by rank, per role. The rank is the tier of the player whose match history
-- the game came from (riot_fact.match.sample_tier); matchmaking keeps the other nine close to it.
-- Master, Grandmaster and Challenger are grouped as Master+, since the top two hold few games.
-- pick_rate = share of the rank's matches with the champion in that role.
CREATE OR REPLACE TABLE riot_mart.champion_rank_win_rate AS
WITH ranked AS (
    SELECT m.match_id, m.patch,
           IF(m.sample_tier IN ('MASTER', 'GRANDMASTER', 'CHALLENGER'), 'MASTER+', m.sample_tier) AS rank_band
    FROM riot_mart.valid_match AS m
    WHERE m.sample_tier IS NOT NULL
),
band AS (
    SELECT patch, rank_band, COUNT(*) AS matches
    FROM ranked
    GROUP BY patch, rank_band
)
SELECT r.patch,
       p.champion_id,
       p.team_position                  AS role,
       r.rank_band,
       COUNT(*)                         AS games,
       COUNTIF(p.win)                   AS wins,
       COUNTIF(p.win) / COUNT(*)        AS win_rate,
       COUNT(*) / MAX(b.matches)        AS pick_rate
FROM ranked AS r
JOIN band AS b ON b.patch = r.patch AND b.rank_band = r.rank_band
JOIN riot_fact.match_participant AS p ON p.match_id = r.match_id
WHERE p.team_position IS NOT NULL
GROUP BY r.patch, p.champion_id, p.team_position, r.rank_band;
