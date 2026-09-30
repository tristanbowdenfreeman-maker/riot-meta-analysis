-- How often a team gold lead at 10, 15, 20 or 25 minutes turns into a win, by size of lead.
-- Only games still going at that minute count, and exact ties are left out.
CREATE OR ALTER VIEW mart.v_gold_lead_win_rate
AS
WITH team_gold AS (
    SELECT t.patch, t.match_id, t.team_id, t.win, f.minute, SUM(f.total_gold) AS gold
    FROM mart.v_team_result AS t
    JOIN fact.match_participant AS p ON p.match_id = t.match_id AND p.team_id = t.team_id
    JOIN fact.participant_frame AS f ON f.match_id = p.match_id AND f.participant_id = p.participant_id
    GROUP BY t.patch, t.match_id, t.team_id, t.win, f.minute
), lead AS (
    SELECT b.patch, b.minute,
           ABS(b.gold - r.gold)                                 AS gold_lead,
           IIF(b.gold > r.gold, b.win, r.win)                   AS leader_won
    FROM team_gold AS b
    JOIN team_gold AS r ON r.match_id = b.match_id AND r.minute = b.minute AND r.team_id = 200
    WHERE b.team_id = 100 AND b.gold <> r.gold
)
SELECT l.patch, l.minute, bd.band_min, bd.band_max,
       COUNT(*)                                              AS games,
       SUM(l.leader_won)                                     AS wins,
       CAST(SUM(l.leader_won) AS FLOAT) / COUNT(*)           AS win_rate,
       1.96 * SQRT(0.25 / COUNT(*))                          AS win_rate_moe
FROM lead AS l
CROSS APPLY (SELECT CASE WHEN l.gold_lead < 1000 THEN 0 WHEN l.gold_lead < 2000 THEN 1000
                         WHEN l.gold_lead < 3000 THEN 2000 WHEN l.gold_lead < 4000 THEN 3000
                         WHEN l.gold_lead < 6000 THEN 4000 ELSE 6000 END AS band_min) AS b0
CROSS APPLY (SELECT b0.band_min,
                    CASE b0.band_min WHEN 0 THEN 1000 WHEN 1000 THEN 2000 WHEN 2000 THEN 3000
                                     WHEN 3000 THEN 4000 WHEN 4000 THEN 6000 END AS band_max) AS bd
GROUP BY l.patch, l.minute, bd.band_min, bd.band_max;
GO
