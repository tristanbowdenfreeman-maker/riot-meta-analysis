-- Reporting views. Every view is per patch and excludes remakes and non-solo/duo games.
-- The website reads these (via the JSON export) and applies its own minimum-games cutoff.
-- pick_share columns are shares of the champion's games in that role.

-- Matches that count towards the stats: EUW ranked solo/duo, no remakes. EUW players' histories
-- also hold games on other European servers (EUN1_, TR1_, RU_), which are out of scope.
CREATE OR ALTER VIEW mart.v_valid_match
AS
SELECT match_id, patch, game_start_utc, duration_s, sample_tier
FROM fact.match
WHERE queue_id = 420
  AND is_remake = 0
  AND match_id LIKE 'EUW1[_]%';
GO

-- Denominators: pick and ban rates are shares of all valid matches in the patch.
CREATE OR ALTER VIEW mart.v_patch_summary
AS
SELECT patch,
       COUNT(*)                   AS matches,
       COUNT(*) * 10              AS player_records,
       MIN(game_start_utc)        AS first_game_utc,
       MAX(game_start_utc)        AS last_game_utc,
       AVG(duration_s) / 60.0     AS avg_duration_min
FROM mart.v_valid_match
GROUP BY patch;
GO

-- How the sample splits across ranks (tier of the player the match was sampled from).
CREATE OR ALTER VIEW mart.v_sample_by_tier
AS
SELECT m.patch,
       ISNULL(m.sample_tier, 'UNKNOWN')                                  AS sample_tier,
       COUNT(*)                                                          AS matches,
       CAST(COUNT(*) AS FLOAT) / SUM(COUNT(*)) OVER (PARTITION BY m.patch) AS share_of_matches
FROM mart.v_valid_match AS m
GROUP BY m.patch, m.sample_tier;
GO

-- Tier list: one row per champion per role per patch.
CREATE OR ALTER VIEW mart.v_champion_role_stats
AS
WITH picks AS (
    SELECT m.patch,
           p.champion_id,
           p.team_position                        AS role,
           COUNT(*)                               AS games,
           SUM(CAST(p.win AS INT))                AS wins,
           SUM(p.kills)                           AS kills,
           SUM(p.deaths)                          AS deaths,
           SUM(p.assists)                         AS assists,
           SUM(p.creep_score)                     AS creep_score,
           SUM(m.duration_s) / 60.0               AS minutes_played,
           SUM(CAST(p.damage_to_champions AS BIGINT)) AS damage_to_champions,
           SUM(p.vision_score)                    AS vision_score
    FROM mart.v_valid_match AS m
    JOIN fact.match_participant AS p ON p.match_id = m.match_id
    WHERE p.team_position IS NOT NULL
    GROUP BY m.patch, p.champion_id, p.team_position
),
bans AS (
    SELECT m.patch, b.champion_id, COUNT(DISTINCT b.match_id) AS banned_matches
    FROM mart.v_valid_match AS m
    JOIN fact.match_ban AS b ON b.match_id = m.match_id
    GROUP BY m.patch, b.champion_id
)
SELECT pk.patch,
       pk.champion_id,
       c.champion_name,
       c.primary_class,
       pk.role,
       pk.games,
       pk.wins,
       CAST(pk.wins AS FLOAT) / pk.games                                           AS win_rate,
       CAST(pk.games AS FLOAT) / t.matches                                         AS pick_rate,
       CAST(ISNULL(bn.banned_matches, 0) AS FLOAT) / t.matches                     AS ban_rate,
       -- Share of this champion's games played in this role (e.g. 0.85 of Ashe games are BOTTOM)
       CAST(pk.games AS FLOAT) / SUM(pk.games) OVER (PARTITION BY pk.patch, pk.champion_id) AS role_share,
       CAST(pk.kills + pk.assists AS FLOAT) / NULLIF(pk.deaths, 0)                AS kda,
       pk.creep_score / NULLIF(pk.minutes_played, 0)                               AS cs_per_min,
       pk.damage_to_champions / NULLIF(pk.minutes_played, 0)                       AS damage_per_min,
       pk.vision_score / NULLIF(pk.minutes_played, 0)                              AS vision_per_min
FROM picks AS pk
JOIN mart.v_patch_summary AS t ON t.patch = pk.patch
LEFT JOIN bans AS bn ON bn.patch = pk.patch AND bn.champion_id = pk.champion_id
LEFT JOIN dim.champion AS c ON c.champion_id = pk.champion_id;
GO

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

------------------------------------------------------------------------------------------
-- Build order, from the timeline (docs/adr/0007)
------------------------------------------------------------------------------------------

-- Player records in valid matches whose timeline has been loaded: the base for every
-- build-order view, so shares are out of players we can actually see the purchases of.
CREATE OR ALTER VIEW mart.v_timeline_participant
AS
SELECT m.patch, p.match_id, p.participant_id, p.champion_id, p.team_position AS role, p.win
FROM mart.v_valid_match AS m
JOIN fact.match_timeline AS t ON t.match_id = m.match_id
JOIN fact.match_participant AS p ON p.match_id = m.match_id
WHERE p.team_position IS NOT NULL;
GO

-- Purchases that were not undone. An undo reverts the most recent purchase of that item, so a
-- purchase counts as undone when an undo of the same item follows it before the item is bought
-- again. (Two purchases of the same item followed by two undos would keep the first one; that
-- only happens with consumables and doesn't affect completed items.)
CREATE OR ALTER VIEW mart.v_item_purchase
AS
WITH purchase AS (
    SELECT e.match_id, e.participant_id, e.item_id, e.event_seq, e.timestamp_ms,
           LEAD(e.event_seq) OVER (PARTITION BY e.match_id, e.participant_id, e.item_id
                                   ORDER BY e.event_seq) AS next_purchase_seq
    FROM fact.item_event AS e
    WHERE e.event_type = 'ITEM_PURCHASED'
)
SELECT p.match_id, p.participant_id, p.item_id, p.event_seq, p.timestamp_ms
FROM purchase AS p
WHERE NOT EXISTS (
    SELECT 1
    FROM fact.item_event AS u
    WHERE u.match_id = p.match_id
      AND u.participant_id = p.participant_id
      AND u.item_id = p.item_id
      AND u.event_type = 'ITEM_UNDO'
      AND u.event_seq > p.event_seq
      AND (p.next_purchase_seq IS NULL OR u.event_seq < p.next_purchase_seq)
);
GO

-- Each player's completed items numbered in the order they were first bought (1st item, 2nd item...).
CREATE OR ALTER VIEW mart.v_completed_item_order
AS
SELECT x.match_id, x.participant_id, x.item_id,
       ROW_NUMBER() OVER (PARTITION BY x.match_id, x.participant_id ORDER BY x.first_seq) AS item_number
FROM (
    SELECT ip.match_id, ip.participant_id, ip.item_id, MIN(ip.event_seq) AS first_seq
    FROM mart.v_item_purchase AS ip
    JOIN dim.item AS d ON d.item_id = ip.item_id
    WHERE d.item_class = 'Completed'
    GROUP BY ip.match_id, ip.participant_id, ip.item_id
) AS x;
GO

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

-- First pair of boots bought (tier 2 boots; the 300-gold Boots component is not in the Boots class).
CREATE OR ALTER VIEW mart.v_champion_boots
AS
WITH first_boots AS (
    SELECT ip.match_id, ip.participant_id, ip.item_id,
           ROW_NUMBER() OVER (PARTITION BY ip.match_id, ip.participant_id ORDER BY ip.event_seq) AS n
    FROM mart.v_item_purchase AS ip
    JOIN dim.item AS d ON d.item_id = ip.item_id
    WHERE d.item_class = 'Boots'
),
base AS (
    SELECT patch, champion_id, role, COUNT(*) AS games
    FROM mart.v_timeline_participant
    GROUP BY patch, champion_id, role
)
SELECT tp.patch,
       tp.champion_id,
       tp.role,
       fb.item_id,
       d.item_name,
       COUNT(*)                                             AS games,
       SUM(CAST(tp.win AS INT))                             AS wins,
       CAST(SUM(CAST(tp.win AS INT)) AS FLOAT) / COUNT(*)   AS win_rate,
       CAST(COUNT(*) AS FLOAT) / MAX(b.games)               AS pick_share
FROM mart.v_timeline_participant AS tp
JOIN first_boots AS fb ON fb.match_id = tp.match_id AND fb.participant_id = tp.participant_id AND fb.n = 1
JOIN dim.item AS d ON d.item_id = fb.item_id
JOIN base AS b ON b.patch = tp.patch AND b.champion_id = tp.champion_id AND b.role = tp.role
GROUP BY tp.patch, tp.champion_id, tp.role, fb.item_id, d.item_name;
GO

-- Core builds: the first three completed items, in order. Only players who finished three.
CREATE OR ALTER VIEW mart.v_champion_core_builds
AS
WITH core AS (
    SELECT match_id, participant_id,
           MAX(CASE WHEN item_number = 1 THEN item_id END) AS item1_id,
           MAX(CASE WHEN item_number = 2 THEN item_id END) AS item2_id,
           MAX(CASE WHEN item_number = 3 THEN item_id END) AS item3_id
    FROM mart.v_completed_item_order
    WHERE item_number <= 3
    GROUP BY match_id, participant_id
    HAVING COUNT(*) = 3
),
base AS (
    SELECT patch, champion_id, role, COUNT(*) AS games
    FROM mart.v_timeline_participant
    GROUP BY patch, champion_id, role
)
SELECT tp.patch,
       tp.champion_id,
       tp.role,
       c.item1_id,
       c.item2_id,
       c.item3_id,
       COUNT(*)                                             AS games,
       SUM(CAST(tp.win AS INT))                             AS wins,
       CAST(SUM(CAST(tp.win AS INT)) AS FLOAT) / COUNT(*)   AS win_rate,
       CAST(COUNT(*) AS FLOAT) / MAX(b.games)               AS pick_share
FROM mart.v_timeline_participant AS tp
JOIN core AS c ON c.match_id = tp.match_id AND c.participant_id = tp.participant_id
JOIN base AS b ON b.patch = tp.patch AND b.champion_id = tp.champion_id AND b.role = tp.role
GROUP BY tp.patch, tp.champion_id, tp.role, c.item1_id, c.item2_id, c.item3_id;
GO

-- Late items: completed items built 4th, 5th or 6th, in one list. Games average under 30 minutes,
-- so few players reach a 5th or 6th item and a separate list per slot would be mostly empty.
-- pick_share is the share of the champion's players who reached a 4th item that built this item
-- 4th to 6th. A player can build up to three late items, so the shares add up to between 1 and 3.
DROP VIEW IF EXISTS mart.v_champion_item_slots;
GO

CREATE OR ALTER VIEW mart.v_champion_late_items
AS
WITH late AS (
    SELECT tp.patch, tp.champion_id, tp.role, tp.win, o.item_id, o.item_number
    FROM mart.v_timeline_participant AS tp
    JOIN mart.v_completed_item_order AS o ON o.match_id = tp.match_id AND o.participant_id = tp.participant_id
    WHERE o.item_number BETWEEN 4 AND 6
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
       CAST(COUNT(*) AS FLOAT) / r.players                 AS pick_share
FROM late AS l
JOIN reached AS r ON r.patch = l.patch AND r.champion_id = l.champion_id AND r.role = l.role
GROUP BY l.patch, l.champion_id, l.role, l.item_id, r.players;
GO

-- Rune pages: keystone plus primary/secondary tree combinations. page_rank 1 is the most played
-- (ties broken by id so the ranking is stable); the rune grid below covers pages 1 and 2.
CREATE OR ALTER VIEW mart.v_champion_rune_stats
AS
SELECT m.patch,
       p.champion_id,
       p.team_position                                          AS role,
       p.keystone_id,
       k.rune_name                                              AS keystone_name,
       p.primary_tree_id,
       t1.tree_name                                             AS primary_tree_name,
       p.secondary_tree_id,
       t2.tree_name                                             AS secondary_tree_name,
       COUNT(*)                                                 AS games,
       SUM(CAST(p.win AS INT))                                  AS wins,
       CAST(SUM(CAST(p.win AS INT)) AS FLOAT) / COUNT(*)        AS win_rate,
       CAST(COUNT(*) AS FLOAT)
           / SUM(COUNT(*)) OVER (PARTITION BY m.patch, p.champion_id, p.team_position) AS pick_share,
       ROW_NUMBER() OVER (PARTITION BY m.patch, p.champion_id, p.team_position
                          ORDER BY COUNT(*) DESC, p.keystone_id, p.secondary_tree_id)  AS page_rank
FROM mart.v_valid_match AS m
JOIN fact.match_participant AS p ON p.match_id = m.match_id
LEFT JOIN dim.rune AS k       ON k.rune_id = p.keystone_id
LEFT JOIN dim.rune_tree AS t1 ON t1.tree_id = p.primary_tree_id
LEFT JOIN dim.rune_tree AS t2 ON t2.tree_id = p.secondary_tree_id
WHERE p.team_position IS NOT NULL
GROUP BY m.patch, p.champion_id, p.team_position, p.keystone_id, k.rune_name,
         p.primary_tree_id, t1.tree_name, p.secondary_tree_id, t2.tree_name;
GO

-- Players on each champion's two most played rune pages, for the rune grid and shards below.
CREATE OR ALTER VIEW mart.v_rune_page_player
AS
SELECT rs.patch, rs.champion_id, rs.role, rs.page_rank, rs.games AS page_games,
       p.match_id, p.participant_id, p.win, p.shard_offense_id, p.shard_flex_id, p.shard_defense_id
FROM mart.v_champion_rune_stats AS rs
JOIN mart.v_valid_match AS m ON m.patch = rs.patch
JOIN fact.match_participant AS p
  ON p.match_id = m.match_id
 AND p.champion_id = rs.champion_id
 AND p.team_position = rs.role
 AND p.keystone_id = rs.keystone_id
 AND p.primary_tree_id = rs.primary_tree_id
 AND p.secondary_tree_id = rs.secondary_tree_id
WHERE rs.page_rank <= 2;
GO

-- Every rune on a rune page, for the rune grid: how often players on that page take it, and its
-- win rate. pick_share is out of the page's games, so each row of the grid adds up to 1.
CREATE OR ALTER VIEW mart.v_champion_rune_picks
AS
SELECT pp.patch,
       pp.champion_id,
       pp.role,
       pp.page_rank,
       r.rune_id,
       r.tree_id,
       r.is_primary_tree,
       COUNT(*)                                                 AS games,
       SUM(CAST(pp.win AS INT))                                 AS wins,
       CAST(SUM(CAST(pp.win AS INT)) AS FLOAT) / COUNT(*)       AS win_rate,
       CAST(COUNT(*) AS FLOAT) / MAX(pp.page_games)             AS pick_share
FROM mart.v_rune_page_player AS pp
JOIN fact.participant_rune AS r ON r.match_id = pp.match_id AND r.participant_id = pp.participant_id
GROUP BY pp.patch, pp.champion_id, pp.role, pp.page_rank, r.rune_id, r.tree_id, r.is_primary_tree;
GO

-- Stat shards on each rune page, by row (1 = offense, 2 = flex, 3 = defense).
CREATE OR ALTER VIEW mart.v_champion_shard_picks
AS
SELECT pp.patch,
       pp.champion_id,
       pp.role,
       pp.page_rank,
       s.shard_row,
       s.shard_id,
       COUNT(*)                                                 AS games,
       SUM(CAST(pp.win AS INT))                                 AS wins,
       CAST(SUM(CAST(pp.win AS INT)) AS FLOAT) / COUNT(*)       AS win_rate,
       CAST(COUNT(*) AS FLOAT)
           / SUM(COUNT(*)) OVER (PARTITION BY pp.patch, pp.champion_id, pp.role, pp.page_rank, s.shard_row) AS pick_share
FROM mart.v_rune_page_player AS pp
CROSS APPLY (VALUES (1, pp.shard_offense_id), (2, pp.shard_flex_id), (3, pp.shard_defense_id)) AS s (shard_row, shard_id)
WHERE s.shard_id IS NOT NULL
GROUP BY pp.patch, pp.champion_id, pp.role, pp.page_rank, s.shard_row, s.shard_id;
GO

-- Summoner spell pairs. Flash on D and on F count as the same pair.
CREATE OR ALTER VIEW mart.v_champion_spell_stats
AS
WITH spells AS (
    SELECT m.patch, p.champion_id, p.team_position AS role, p.win,
           IIF(p.summoner1_id < p.summoner2_id, p.summoner1_id, p.summoner2_id) AS spell_a_id,
           IIF(p.summoner1_id < p.summoner2_id, p.summoner2_id, p.summoner1_id) AS spell_b_id
    FROM mart.v_valid_match AS m
    JOIN fact.match_participant AS p ON p.match_id = m.match_id
    WHERE p.team_position IS NOT NULL
)
SELECT s.patch,
       s.champion_id,
       s.role,
       s.spell_a_id,
       sa.spell_name                                            AS spell_a_name,
       s.spell_b_id,
       sb.spell_name                                            AS spell_b_name,
       COUNT(*)                                                 AS games,
       SUM(CAST(s.win AS INT))                                  AS wins,
       CAST(SUM(CAST(s.win AS INT)) AS FLOAT) / COUNT(*)        AS win_rate,
       CAST(COUNT(*) AS FLOAT)
           / SUM(COUNT(*)) OVER (PARTITION BY s.patch, s.champion_id, s.role) AS pick_share
FROM spells AS s
LEFT JOIN dim.summoner_spell AS sa ON sa.spell_id = s.spell_a_id
LEFT JOIN dim.summoner_spell AS sb ON sb.spell_id = s.spell_b_id
GROUP BY s.patch, s.champion_id, s.role, s.spell_a_id, sa.spell_name, s.spell_b_id, sb.spell_name;
GO

-- Lane matchups: each player against the enemy in the same role.
CREATE OR ALTER VIEW mart.v_champion_matchups
AS
SELECT m.patch,
       a.champion_id,
       a.team_position                                          AS role,
       b.champion_id                                            AS opponent_id,
       c.champion_name                                          AS opponent_name,
       COUNT(*)                                                 AS games,
       SUM(CAST(a.win AS INT))                                  AS wins,
       CAST(SUM(CAST(a.win AS INT)) AS FLOAT) / COUNT(*)        AS win_rate
FROM mart.v_valid_match AS m
JOIN fact.match_participant AS a ON a.match_id = m.match_id
JOIN fact.match_participant AS b
  ON b.match_id = a.match_id
 AND b.team_position = a.team_position
 AND b.team_id <> a.team_id
LEFT JOIN dim.champion AS c ON c.champion_id = b.champion_id
WHERE a.team_position IS NOT NULL
GROUP BY m.patch, a.champion_id, a.team_position, b.champion_id, c.champion_name;
GO

-- Tier list. Champions are ranked within each role by an adjusted win rate that adds 50 wins
-- and 50 losses to their record, which pulls small samples towards 50%: 18-12 (60%) becomes
-- 68-62 (52.3%), while 159-141 (53%) only moves to 52.3%. Tiers are cut by rank within the role.
-- Only champion/role pairs picked in at least 1% of matches and making up at least 10% of
-- the champion's games are ranked; the rest get no tier.
CREATE OR ALTER VIEW mart.v_tier_list
AS
WITH scored AS (
    SELECT r.*,
           (r.wins + 50.0) / (r.games + 100.0) AS adjusted_win_rate,
           CASE WHEN r.pick_rate >= 0.01 AND r.role_share >= 0.10 THEN 1 ELSE 0 END AS is_ranked
    FROM mart.v_champion_role_stats AS r
),
ranked AS (
    SELECT s.*,
           CASE WHEN s.is_ranked = 1
                THEN PERCENT_RANK() OVER (PARTITION BY s.patch, s.role, s.is_ranked
                                          ORDER BY s.adjusted_win_rate DESC) END AS role_percentile
    FROM scored AS s
)
SELECT patch, champion_id, champion_name, primary_class, role, games, wins, win_rate, pick_rate,
       ban_rate, role_share, kda, cs_per_min, damage_per_min, vision_per_min, adjusted_win_rate,
       role_percentile,
       CASE
           WHEN role_percentile IS NULL THEN NULL
           WHEN role_percentile <= 0.05 THEN 'OP'   -- top 5%
           WHEN role_percentile <= 0.20 THEN '1'    -- next 15%
           WHEN role_percentile <= 0.45 THEN '2'    -- next 25%
           WHEN role_percentile <= 0.75 THEN '3'    -- next 30%
           WHEN role_percentile <= 0.92 THEN '4'    -- next 17%
           ELSE '5'                                  -- bottom 8%
       END AS tier
FROM ranked;
GO
