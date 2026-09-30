-- Which lane's lead matters most: when one laner is 1,000+ gold ahead of the opponent in the
-- same role at that minute, how often their team wins.
CREATE OR ALTER VIEW mart.v_lane_lead_win_rate
AS
WITH laner AS (
    SELECT t.patch, t.match_id, t.team_id, t.win, p.team_position AS role, f.minute, f.total_gold
    FROM mart.v_team_result AS t
    JOIN fact.match_participant AS p ON p.match_id = t.match_id AND p.team_id = t.team_id
    JOIN fact.participant_frame AS f ON f.match_id = p.match_id AND f.participant_id = p.participant_id
    WHERE p.team_position IS NOT NULL
)
SELECT a.patch, a.minute, a.role,
       COUNT(*)                                      AS games,
       SUM(a.win)                                    AS wins,
       CAST(SUM(a.win) AS FLOAT) / COUNT(*)          AS win_rate,
       1.96 * SQRT(0.25 / COUNT(*))                  AS win_rate_moe
FROM laner AS a
JOIN laner AS b ON b.match_id = a.match_id AND b.minute = a.minute AND b.role = a.role AND b.team_id <> a.team_id
WHERE a.total_gold - b.total_gold >= 1000
GROUP BY a.patch, a.minute, a.role;
GO
