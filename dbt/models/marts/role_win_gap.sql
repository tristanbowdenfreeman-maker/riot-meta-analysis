-- Winners against losers in each role: the average of each stat for players who won and for
-- players who lost. gap is winners / losers - 1 (-0.35 = winners have 35% less). Deaths and the
-- first-item time are better when lower. These are outcomes as much as causes: a team that is
-- winning gets kills and gold, which is why the page says "differ", not "cause".
WITH first_item AS (
    SELECT ip.match_id, ip.participant_id, MIN(ip.timestamp_ms) / 60000.0 AS minutes
    FROM {{ ref('item_purchase') }} AS ip
    JOIN {{ ref('stg_dim_item') }} AS d ON d.item_id = ip.item_id
    WHERE d.item_class = 'Completed'
    GROUP BY ip.match_id, ip.participant_id
),
player_stat AS (
    SELECT m.patch, p.team_position AS role, p.win, s.metric_order, s.metric, s.lower_is_better, s.value
    FROM {{ ref('valid_match') }} AS m
    JOIN {{ ref('stg_fact_match_participant') }} AS p ON p.match_id = m.match_id
    LEFT JOIN first_item AS f ON f.match_id = p.match_id AND f.participant_id = p.participant_id
    CROSS JOIN UNNEST([
        STRUCT(1 AS metric_order, 'Deaths' AS metric, TRUE AS lower_is_better, CAST(p.deaths AS FLOAT64) AS value),
        STRUCT(2, 'Kills + assists', FALSE, CAST(p.kills + p.assists AS FLOAT64)),
        STRUCT(3, 'CS / min', FALSE, p.creep_score * 60.0 / m.duration_s),
        STRUCT(4, 'Damage / min', FALSE, p.damage_to_champions * 60.0 / m.duration_s),
        STRUCT(5, 'Vision / min', FALSE, p.vision_score * 60.0 / m.duration_s),
        STRUCT(6, 'First item (min)', TRUE, f.minutes)   -- NULL without a timeline or a completed item
    ]) AS s
    WHERE p.team_position IS NOT NULL
      AND s.value IS NOT NULL
)
SELECT patch,
       role,
       metric_order,
       metric,
       lower_is_better,
       AVG(IF(win, value, NULL))                                        AS winners,
       AVG(IF(NOT win, value, NULL))                                    AS losers,
       AVG(IF(win, value, NULL)) / NULLIF(AVG(IF(NOT win, value, NULL)), 0) - 1 AS gap,
       COUNT(*)                                                         AS players
FROM player_stat
GROUP BY patch, role, metric_order, metric, lower_is_better
