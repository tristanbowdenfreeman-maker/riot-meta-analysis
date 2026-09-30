-- Completed items and boots in the final inventory, per champion and role.
CREATE OR ALTER VIEW mart.v_champion_item_stats
AS
WITH owned AS (
    -- DISTINCT: a player holding two copies of an item counts once.
    SELECT DISTINCT m.patch, p.match_id, p.participant_id, p.champion_id, p.team_position AS role, p.win, i.item_id
    FROM mart.v_valid_match AS m
    JOIN fact.match_participant AS p ON p.match_id = m.match_id
    JOIN fact.participant_item AS i ON i.match_id = p.match_id AND i.participant_id = p.participant_id
    JOIN dim.item AS d ON d.item_id = i.item_id
    WHERE p.team_position IS NOT NULL
      AND d.item_class IN ('Completed', 'Boots')
)
SELECT o.patch,
       o.champion_id,
       o.role,
       o.item_id,
       d.item_name,
       d.item_class,
       COUNT(*)                                             AS games,
       SUM(CAST(o.win AS INT))                              AS wins,
       CAST(SUM(CAST(o.win AS INT)) AS FLOAT) / COUNT(*)    AS win_rate,
       CAST(COUNT(*) AS FLOAT) / cr.games                   AS build_rate,   -- share of the champion's games in this role
       cr.win_rate                                          AS champion_win_rate
FROM owned AS o
JOIN dim.item AS d ON d.item_id = o.item_id
JOIN mart.v_champion_role_stats AS cr
  ON cr.patch = o.patch AND cr.champion_id = o.champion_id AND cr.role = o.role
GROUP BY o.patch, o.champion_id, o.role, o.item_id, d.item_name, d.item_class, cr.games, cr.win_rate;
GO
