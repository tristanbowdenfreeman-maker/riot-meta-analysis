-- Core items: completed items finished 1st, 2nd or 3rd, in one list. Exact
-- three-item orders spread a champion's games over dozens of combinations; counting each item
-- wherever it lands in the first three keeps every champion's list full. avg_slot is where it
-- usually lands (1 = first item). pick_share is out of all the champion's players in the role;
-- a player builds up to three core items, so the shares add up to at most 3.
CREATE OR ALTER VIEW mart.v_champion_core_items
AS
WITH base AS (
    SELECT patch, champion_id, role, COUNT(*) AS games
    FROM mart.v_timeline_participant
    GROUP BY patch, champion_id, role
)
SELECT tp.patch,
       tp.champion_id,
       tp.role,
       o.item_id,
       COUNT(*)                                             AS games,
       SUM(CAST(tp.win AS INT))                             AS wins,
       CAST(SUM(CAST(tp.win AS INT)) AS FLOAT) / COUNT(*)   AS win_rate,
       AVG(CAST(o.item_number AS FLOAT))                    AS avg_slot,
       CAST(COUNT(*) AS FLOAT) / MAX(b.games)               AS pick_share
FROM mart.v_timeline_participant AS tp
JOIN mart.v_completed_item_order AS o
  ON o.match_id = tp.match_id AND o.participant_id = tp.participant_id AND o.item_number <= 3
JOIN base AS b ON b.patch = tp.patch AND b.champion_id = tp.champion_id AND b.role = tp.role
GROUP BY tp.patch, tp.champion_id, tp.role, o.item_id;
GO
