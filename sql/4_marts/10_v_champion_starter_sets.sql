-- Starter sets: everything bought (and kept) in the first 90 seconds, except the trinket.
-- starter_items lists item_id:quantity pairs, e.g. '1055:1,2003:1' = Doran's Blade + Health Potion.
-- The game gives each support a free World Atlas (3865) at 0:00. The timeline logs that grant
-- under participant 0 rather than the support, so it is added here for every UTILITY player.
CREATE OR ALTER VIEW mart.v_champion_starter_sets
AS
WITH starter_purchase AS (
    SELECT ip.match_id, ip.participant_id, ip.item_id
    FROM mart.v_item_purchase AS ip
    LEFT JOIN dim.item AS d ON d.item_id = ip.item_id
    WHERE ip.timestamp_ms < 90000
      AND ISNULL(d.item_class, '') <> 'Trinket'
    UNION ALL
    SELECT tp.match_id, tp.participant_id, 3865
    FROM mart.v_timeline_participant AS tp
    WHERE tp.role = 'UTILITY'
),
starter_item AS (
    SELECT match_id, participant_id, item_id, COUNT(*) AS quantity
    FROM starter_purchase
    GROUP BY match_id, participant_id, item_id
),
starter_set AS (
    SELECT match_id, participant_id,
           STRING_AGG(CONCAT(item_id, ':', quantity), ',') WITHIN GROUP (ORDER BY item_id) AS starter_items
    FROM starter_item
    GROUP BY match_id, participant_id
),
base AS (
    SELECT patch, champion_id, role, COUNT(*) AS games
    FROM mart.v_timeline_participant
    GROUP BY patch, champion_id, role
)
SELECT tp.patch,
       tp.champion_id,
       tp.role,
       s.starter_items,
       COUNT(*)                                             AS games,
       SUM(CAST(tp.win AS INT))                             AS wins,
       CAST(SUM(CAST(tp.win AS INT)) AS FLOAT) / COUNT(*)   AS win_rate,
       CAST(COUNT(*) AS FLOAT) / MAX(b.games)               AS pick_share
FROM mart.v_timeline_participant AS tp
JOIN starter_set AS s ON s.match_id = tp.match_id AND s.participant_id = tp.participant_id
JOIN base AS b ON b.patch = tp.patch AND b.champion_id = tp.champion_id AND b.role = tp.role
GROUP BY tp.patch, tp.champion_id, tp.role, s.starter_items;
GO
