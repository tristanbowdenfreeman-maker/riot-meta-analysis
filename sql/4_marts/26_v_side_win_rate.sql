-- Blue side against red side. Every match has one winner, so the two win rates add up to 1.
CREATE OR ALTER VIEW mart.v_side_win_rate
AS
SELECT m.patch,
       CASE p.team_id WHEN 100 THEN 'Blue' ELSE 'Red' END                  AS side,
       COUNT(DISTINCT m.match_id)                                          AS games,
       COUNT(DISTINCT CASE WHEN p.win = 1 THEN m.match_id END)             AS wins,
       CAST(COUNT(DISTINCT CASE WHEN p.win = 1 THEN m.match_id END) AS FLOAT)
           / COUNT(DISTINCT m.match_id)                                    AS win_rate,
       1.96 * SQRT(0.25 / COUNT(DISTINCT m.match_id))                      AS win_rate_moe
FROM mart.v_valid_match AS m
JOIN fact.match_participant AS p ON p.match_id = m.match_id
GROUP BY m.patch, p.team_id;
GO
