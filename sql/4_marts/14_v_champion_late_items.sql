-- Late items: completed items built after the core, i.e. 4th or later. Only about
-- a quarter of players finish a 4th item in games that average 28 minutes, so the site shows how
-- often each is built but not its win rate: players who get this far are in longer games.
-- pick_share is the share of the champion's players who reached a 4th item that built this item
-- 4th or later. A player can build several late items, so the shares add up to 1 or more.
CREATE OR ALTER VIEW mart.v_champion_late_items
AS
WITH late AS (
    SELECT tp.patch, tp.champion_id, tp.role, tp.win, o.item_id, o.item_number
    FROM mart.v_timeline_participant AS tp
    JOIN mart.v_completed_item_order AS o ON o.match_id = tp.match_id AND o.participant_id = tp.participant_id
    WHERE o.item_number >= 4
),
reached AS (
    SELECT patch, champion_id, role, COUNT(*) AS players
    FROM late
    WHERE item_number = 4
    GROUP BY patch, champion_id, role
)
SELECT l.patch,
       l.champion_id,
       l.role,
       l.item_id,
       COUNT(*)                                            AS games,
       SUM(CAST(l.win AS INT))                             AS wins,
       CAST(SUM(CAST(l.win AS INT)) AS FLOAT) / COUNT(*)   AS win_rate,
       AVG(CAST(l.item_number AS FLOAT))                   AS avg_slot,
       CAST(COUNT(*) AS FLOAT) / r.players                 AS pick_share
FROM late AS l
JOIN reached AS r ON r.patch = l.patch AND r.champion_id = l.champion_id AND r.role = l.role
GROUP BY l.patch, l.champion_id, l.role, l.item_id, r.players;
GO
