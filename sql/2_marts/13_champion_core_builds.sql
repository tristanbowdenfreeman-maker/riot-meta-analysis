-- Core builds: the first three completed items, in order. Only players who finished three.
-- Kept for analysis but not exported: at 4,000 matches most combinations have too few games
-- to show, so the site lists core items instead (champion_core_items).
CREATE OR REPLACE TABLE riot_mart.champion_core_builds AS
WITH core AS (
    SELECT match_id, participant_id,
           MAX(IF(item_number = 1, item_id, NULL)) AS item1_id,
           MAX(IF(item_number = 2, item_id, NULL)) AS item2_id,
           MAX(IF(item_number = 3, item_id, NULL)) AS item3_id
    FROM riot_mart.completed_item_order
    WHERE item_number <= 3
    GROUP BY match_id, participant_id
    HAVING COUNT(*) = 3
),
base AS (
    SELECT patch, champion_id, role, COUNT(*) AS games
    FROM riot_mart.timeline_participant
    GROUP BY patch, champion_id, role
)
SELECT tp.patch,
       tp.champion_id,
       tp.role,
       c.item1_id,
       c.item2_id,
       c.item3_id,
       COUNT(*)                     AS games,
       COUNTIF(tp.win)              AS wins,
       COUNTIF(tp.win) / COUNT(*)   AS win_rate,
       COUNT(*) / MAX(b.games)      AS pick_share
FROM riot_mart.timeline_participant AS tp
JOIN core AS c ON c.match_id = tp.match_id AND c.participant_id = tp.participant_id
JOIN base AS b ON b.patch = tp.patch AND b.champion_id = tp.champion_id AND b.role = tp.role
GROUP BY tp.patch, tp.champion_id, tp.role, c.item1_id, c.item2_id, c.item3_id;
