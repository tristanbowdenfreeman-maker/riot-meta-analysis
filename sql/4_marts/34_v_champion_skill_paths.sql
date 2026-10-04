-- Skill paths per champion and role: the first three skills plus the order Q, W and E are maxed
-- (fact.participant_skills). Slots: 1-3 = Q, W, E; 4 = R. start '312' + max_order '312' = E, Q, W
-- at levels 1-3, then E maxed first, then Q, then W. Only players who reached 11 level-ups count.
-- levels = the skill most often taken at each level 1-18 by players on that path. Paths need 20+ games.
CREATE OR ALTER VIEW mart.v_champion_skill_paths
AS
WITH player AS (
    SELECT m.patch, p.champion_id, p.team_position AS role, CAST(p.win AS INT) AS win,
           s.skill_start AS start, s.max_order, s.skill_levels
    FROM mart.v_valid_match AS m
    JOIN fact.match_participant AS p ON p.match_id = m.match_id
    JOIN fact.participant_skills AS s ON s.match_id = p.match_id AND s.participant_id = p.participant_id
    WHERE p.team_position IS NOT NULL
      AND s.max_order IS NOT NULL
),
path AS (
    SELECT patch, champion_id, role, start, max_order,
           COUNT(*)                                                                    AS games,
           SUM(win)                                                                    AS wins,
           CAST(COUNT(*) AS FLOAT) / SUM(COUNT(*)) OVER (PARTITION BY patch, champion_id, role) AS pick_share
    FROM player
    GROUP BY patch, champion_id, role, start, max_order
),
kept AS (
    SELECT * FROM path WHERE games >= 20
),
level_pick AS (
    SELECT pl.patch, pl.champion_id, pl.role, pl.start, pl.max_order, n.level, SUBSTRING(pl.skill_levels, n.level, 1) AS slot,
           ROW_NUMBER() OVER (PARTITION BY pl.patch, pl.champion_id, pl.role, pl.start, pl.max_order, n.level
                              ORDER BY COUNT(*) DESC, SUBSTRING(pl.skill_levels, n.level, 1)) AS pick
    FROM player AS pl
    JOIN kept AS k ON k.patch = pl.patch AND k.champion_id = pl.champion_id AND k.role = pl.role
                  AND k.start = pl.start AND k.max_order = pl.max_order
    CROSS JOIN (VALUES (1), (2), (3), (4), (5), (6), (7), (8), (9), (10), (11), (12), (13), (14), (15), (16), (17), (18)) AS n (level)
    WHERE LEN(pl.skill_levels) >= n.level
    GROUP BY pl.patch, pl.champion_id, pl.role, pl.start, pl.max_order, n.level, SUBSTRING(pl.skill_levels, n.level, 1)
),
path_levels AS (
    SELECT patch, champion_id, role, start, max_order,
           STRING_AGG(slot, '') WITHIN GROUP (ORDER BY level) AS levels
    FROM level_pick
    WHERE pick = 1
    GROUP BY patch, champion_id, role, start, max_order
)
SELECT k.patch, k.champion_id, k.role, k.start, k.max_order, k.games, k.wins,
       CAST(k.wins AS FLOAT) / k.games AS win_rate,
       k.pick_share,
       l.levels
FROM kept AS k
JOIN path_levels AS l
  ON l.patch = k.patch AND l.champion_id = k.champion_id AND l.role = k.role
 AND l.start = k.start AND l.max_order = k.max_order;
GO
