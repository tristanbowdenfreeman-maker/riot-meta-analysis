-- First pair of boots bought (tier 2 boots; the 300-gold Boots component is not in the Boots class).
CREATE OR REPLACE TABLE riot_mart.champion_boots AS
WITH first_boots AS (
    SELECT ip.match_id, ip.participant_id, ip.item_id,
           ROW_NUMBER() OVER (PARTITION BY ip.match_id, ip.participant_id ORDER BY ip.event_seq) AS n
    FROM riot_mart.item_purchase AS ip
    JOIN riot_dim.item AS d ON d.item_id = ip.item_id
    WHERE d.item_class = 'Boots'
),
base AS (
    SELECT patch, champion_id, role, COUNT(*) AS games
    FROM riot_mart.timeline_participant
    GROUP BY patch, champion_id, role
)
SELECT tp.patch,
       tp.champion_id,
       tp.role,
       fb.item_id,
       d.item_name,
       COUNT(*)                     AS games,
       COUNTIF(tp.win)              AS wins,
       COUNTIF(tp.win) / COUNT(*)   AS win_rate,
       COUNT(*) / MAX(b.games)      AS pick_share
FROM riot_mart.timeline_participant AS tp
JOIN first_boots AS fb ON fb.match_id = tp.match_id AND fb.participant_id = tp.participant_id AND fb.n = 1
JOIN riot_dim.item AS d ON d.item_id = fb.item_id
JOIN base AS b ON b.patch = tp.patch AND b.champion_id = tp.champion_id AND b.role = tp.role
GROUP BY tp.patch, tp.champion_id, tp.role, fb.item_id, d.item_name;
