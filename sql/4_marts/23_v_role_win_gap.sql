-- Winners against losers in each role: the average of each stat for players who won and for
-- players who lost. gap is winners / losers - 1 (-0.35 = winners have 35% less). Deaths and the
-- first-item time are better when lower. These are outcomes as much as causes: a team that is
-- winning gets kills and gold, which is why the page says "differ", not "cause".
CREATE OR ALTER VIEW mart.v_role_win_gap
AS
WITH first_item AS (
    SELECT ip.match_id, ip.participant_id, MIN(ip.timestamp_ms) / 60000.0 AS minutes
    FROM mart.v_item_purchase AS ip
    JOIN dim.item AS d ON d.item_id = ip.item_id
    WHERE d.item_class = 'Completed'
    GROUP BY ip.match_id, ip.participant_id
),
player_stat AS (
    SELECT m.patch, p.team_position AS role, p.win, s.metric_order, s.metric, s.lower_is_better, s.value
    FROM mart.v_valid_match AS m
    JOIN fact.match_participant AS p ON p.match_id = m.match_id
    LEFT JOIN first_item AS f ON f.match_id = p.match_id AND f.participant_id = p.participant_id
    CROSS APPLY (VALUES
        (1, 'Deaths',          1, CAST(p.deaths AS FLOAT)),
        (2, 'Kills + assists', 0, CAST(p.kills + p.assists AS FLOAT)),
        (3, 'CS / min',        0, p.creep_score * 60.0 / m.duration_s),
        (4, 'Damage / min',    0, p.damage_to_champions * 60.0 / m.duration_s),
        (5, 'Vision / min',    0, p.vision_score * 60.0 / m.duration_s),
        (6, 'First item (min)', 1, f.minutes)   -- NULL without a timeline or a completed item
    ) AS s (metric_order, metric, lower_is_better, value)
    WHERE p.team_position IS NOT NULL
      AND s.value IS NOT NULL
)
SELECT patch,
       role,
       metric_order,
       metric,
       CAST(lower_is_better AS BIT)                                          AS lower_is_better,
       AVG(CASE WHEN win = 1 THEN value END)                                 AS winners,
       AVG(CASE WHEN win = 0 THEN value END)                                 AS losers,
       AVG(CASE WHEN win = 1 THEN value END)
           / NULLIF(AVG(CASE WHEN win = 0 THEN value END), 0) - 1            AS gap,
       COUNT(*)                                                              AS players
FROM player_stat
GROUP BY patch, role, metric_order, metric, lower_is_better;
GO
