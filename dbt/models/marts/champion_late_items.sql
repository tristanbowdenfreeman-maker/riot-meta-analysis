-- Late items: completed items built after the core, i.e. 4th or later. Only about
-- a quarter of players finish a 4th item in games that average 28 minutes, so the site shows how
-- often each is built but not its win rate: players who get this far are in longer games.
-- pick_share is the share of the champion's players who reached a 4th item that built this item
-- 4th or later. A player can build several late items, so the shares add up to 1 or more.
WITH late AS (
    SELECT tp.patch, tp.champion_id, tp.role, tp.win, o.item_id, o.item_number
    FROM {{ ref('timeline_participant') }} AS tp
    JOIN {{ ref('completed_item_order') }} AS o ON o.match_id = tp.match_id AND o.participant_id = tp.participant_id
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
       COUNT(*)                    AS games,
       COUNTIF(l.win)              AS wins,
       COUNTIF(l.win) / COUNT(*)   AS win_rate,
       SUM(l.item_number) / COUNT(*) AS avg_slot,  -- exact; AVG can differ in the last bit run to run
       COUNT(*) / r.players        AS pick_share
FROM late AS l
JOIN reached AS r ON r.patch = l.patch AND r.champion_id = l.champion_id AND r.role = l.role
GROUP BY l.patch, l.champion_id, l.role, l.item_id, r.players
