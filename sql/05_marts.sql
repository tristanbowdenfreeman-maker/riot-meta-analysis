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

-- The size of the data behind each patch, for the headline figures on the site.
-- Each count is a seek on the match_id key, so this stays cheap as the tables grow.
CREATE OR ALTER VIEW mart.v_data_volume
AS
SELECT m.patch,
       COUNT(*)                                                                    AS matches,
       COUNT(*) * 10                                                               AS player_records,
       SUM(t.timelines)                                                            AS timelines,
       SUM(e.item_events)                                                          AS item_events,
       SUM(r.rune_choices)                                                         AS rune_choices,
       SUM(b.bans)                                                                 AS bans,
       (SELECT COUNT(*) FROM stg.player)                                           AS ladder_players,
       SUM(DATALENGTH(mr.payload_gz) + ISNULL(DATALENGTH(tr.payload_gz), 0)) / 1048576.0 AS raw_json_mb,
       SUM(o.objectives)                                                           AS objective_rows,
       SUM(f.gold_frames)                                                          AS gold_frames,
       -- Every fact row behind the patch: matches, players, inventories, runes, bans, item events,
       -- team objectives and gold frames.
       COUNT(*) * 11 + SUM(i.inventory_items) + SUM(r.rune_choices) + SUM(b.bans) + SUM(e.item_events)
           + SUM(o.objectives) + SUM(f.gold_frames)                                AS fact_rows,
       (SELECT COUNT(*) FROM sys.views WHERE schema_id = SCHEMA_ID(N'mart'))       AS mart_views
FROM mart.v_valid_match AS m
JOIN stg.match_raw AS mr ON mr.match_id = m.match_id
LEFT JOIN stg.timeline_raw AS tr ON tr.match_id = m.match_id
OUTER APPLY (SELECT COUNT(*) AS timelines FROM fact.match_timeline AS x WHERE x.match_id = m.match_id) AS t
OUTER APPLY (SELECT COUNT(*) AS item_events FROM fact.item_event AS x WHERE x.match_id = m.match_id) AS e
OUTER APPLY (SELECT COUNT(*) AS rune_choices FROM fact.participant_rune AS x WHERE x.match_id = m.match_id) AS r
OUTER APPLY (SELECT COUNT(*) AS bans FROM fact.match_ban AS x WHERE x.match_id = m.match_id) AS b
OUTER APPLY (SELECT COUNT(*) AS inventory_items FROM fact.participant_item AS x WHERE x.match_id = m.match_id) AS i
OUTER APPLY (SELECT COUNT(*) AS objectives FROM fact.team_objective AS x WHERE x.match_id = m.match_id) AS o
OUTER APPLY (SELECT COUNT(*) AS gold_frames FROM fact.participant_frame AS x WHERE x.match_id = m.match_id) AS f
GROUP BY m.patch;
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
       pk.vision_score / NULLIF(pk.minutes_played, 0)                              AS vision_per_min,
       -- The same four stats for everyone in the role, for comparison on the champion page.
       CAST(SUM(pk.kills + pk.assists) OVER role_total AS FLOAT)
           / NULLIF(SUM(pk.deaths) OVER role_total, 0)                             AS role_kda,
       SUM(pk.creep_score) OVER role_total / NULLIF(SUM(pk.minutes_played) OVER role_total, 0)
                                                                                   AS role_cs_per_min,
       SUM(pk.damage_to_champions) OVER role_total / NULLIF(SUM(pk.minutes_played) OVER role_total, 0)
                                                                                   AS role_damage_per_min,
       SUM(pk.vision_score) OVER role_total / NULLIF(SUM(pk.minutes_played) OVER role_total, 0)
                                                                                   AS role_vision_per_min
FROM picks AS pk
JOIN mart.v_patch_summary AS t ON t.patch = pk.patch
LEFT JOIN bans AS bn ON bn.patch = pk.patch AND bn.champion_id = pk.champion_id
LEFT JOIN dim.champion AS c ON c.champion_id = pk.champion_id
WINDOW role_total AS (PARTITION BY pk.patch, pk.role);
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

-- Core items: completed items finished 1st, 2nd or 3rd, in one list (docs/adr/0010). Exact
-- three-item orders spread a champion's games over dozens of combinations; counting each item
-- wherever it lands in the first three keeps every champion's list full. avg_slot is where it
-- usually lands (1 = first item). pick_share is out of all the champion's players in the role;
-- a player builds up to three core items, so the shares add up to at most 3.
DROP VIEW IF EXISTS mart.v_champion_first_items;
GO

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

-- Core builds: the first three completed items, in order. Only players who finished three.
-- Kept for analysis but not exported: at 4,000 matches most combinations have too few games
-- to show, so the site lists core items instead (v_champion_core_items).
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

-- Late items: completed items built after the core, i.e. 4th or later (docs/adr/0010). Only about
-- a quarter of players finish a 4th item in games that average 28 minutes, so the site shows how
-- often each is built but not its win rate: players who get this far are in longer games.
-- pick_share is the share of the champion's players who reached a 4th item that built this item
-- 4th or later. A player can build several late items, so the shares add up to 1 or more.
DROP VIEW IF EXISTS mart.v_champion_item_slots;
GO

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

-- Lane matchups grouped by the opponent's class (docs/adr/0010). Single champion pairs are too
-- small at this sample size (a typical pair has under 10 games); six classes give each
-- champion a full list with enough games per row to read. pick_share is how often the champion
-- faced that class in lane.
CREATE OR ALTER VIEW mart.v_champion_class_matchups
AS
WITH faced AS (
    SELECT m.patch,
           a.champion_id,
           a.team_position                                      AS role,
           ISNULL(c.primary_class, 'Unknown')                   AS opponent_class,
           COUNT(*)                                             AS games,
           SUM(CAST(a.win AS INT))                              AS wins
    FROM mart.v_valid_match AS m
    JOIN fact.match_participant AS a ON a.match_id = m.match_id
    JOIN fact.match_participant AS b
      ON b.match_id = a.match_id
     AND b.team_position = a.team_position
     AND b.team_id <> a.team_id
    LEFT JOIN dim.champion AS c ON c.champion_id = b.champion_id
    WHERE a.team_position IS NOT NULL
    GROUP BY m.patch, a.champion_id, a.team_position, c.primary_class
)
SELECT f.patch, f.champion_id, f.role, f.opponent_class, f.games, f.wins,
       CAST(f.wins AS FLOAT) / f.games                                                    AS win_rate,
       CAST(f.games AS FLOAT) / SUM(f.games) OVER (PARTITION BY f.patch, f.champion_id, f.role) AS pick_share
FROM faced AS f;
GO

-- Tier list. Champions are ranked within each role by an adjusted win rate: their record plus
-- prior_games extra games at 50%, which pulls small samples towards 50% (docs/adr/0009).
-- prior_games is estimated from the data (empirical Bayes, method of moments). Win rates differ
-- between champions partly for real and partly by chance; the chance part is known
-- (p(1 - p) / games), so subtracting it from the observed variance leaves the real variance.
-- The smaller the real differences, the more games a champion needs before its own record
-- outweighs 50%: prior_games = 0.25 / real variance. On 3,000 matches real win rates spread by
-- about 3 points either side of 50%, which gives about 255 games: 38-18 (67.9%) becomes 53.2%,
-- while 211-153 (58.0%) only falls to 54.7%.
-- win_rate_moe is the 95% margin of error of the raw win rate (1.96 standard errors).
-- Only champion/role pairs picked in at least 1% of matches and making up at least 10% of the
-- champion's games are ranked; the rest get no tier. Tiers are cut by rank within the role.
CREATE OR ALTER VIEW mart.v_tier_list
AS
WITH scored AS (
    SELECT r.*,
           CASE WHEN r.pick_rate >= 0.01 AND r.role_share >= 0.10 THEN 1 ELSE 0 END AS is_ranked
    FROM mart.v_champion_role_stats AS r
),
prior AS (
    -- The floor on the real variance caps prior_games at 2,500 if the chance part explains it all.
    SELECT patch,
           0.25 / GREATEST(VAR(win_rate) - AVG(win_rate * (1 - win_rate) / games), 0.0001) AS prior_games
    FROM scored
    WHERE is_ranked = 1
    GROUP BY patch
),
adjusted AS (
    SELECT s.*,
           p.prior_games,
           (s.wins + p.prior_games / 2) / (s.games + p.prior_games)  AS adjusted_win_rate,
           1.96 * SQRT(s.win_rate * (1 - s.win_rate) / s.games)     AS win_rate_moe
    FROM scored AS s
    JOIN prior AS p ON p.patch = s.patch
),
ranked AS (
    SELECT a.*,
           CASE WHEN a.is_ranked = 1
                THEN PERCENT_RANK() OVER (PARTITION BY a.patch, a.role, a.is_ranked
                                          ORDER BY a.adjusted_win_rate DESC) END AS role_percentile
    FROM adjusted AS a
)
SELECT patch, champion_id, champion_name, primary_class, role, games, wins, win_rate, win_rate_moe,
       pick_rate, ban_rate, role_share, kda, cs_per_min, damage_per_min, vision_per_min,
       role_kda, role_cs_per_min, role_damage_per_min, role_vision_per_min,
       prior_games, adjusted_win_rate, role_percentile,
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

------------------------------------------------------------------------------------------
-- Insights page
------------------------------------------------------------------------------------------

-- Winners against losers in each role: the average of each stat for players who won and for
-- players who lost. gap is winners / losers - 1 (-0.35 = winners have 35% less). Deaths and the
-- first-item time are better when lower. These are outcomes as much as causes: a team that is
-- winning gets kills and gold, which is why the page says "differ", not "cause".
CREATE OR ALTER VIEW mart.v_role_win_gap
AS
WITH first_item AS (
    SELECT ip.match_id, ip.participant_id, MIN(ip.timestamp_ms) / 60000.0 AS minutes
    FROM mart.v_item_purchase AS ip
    JOIN dim.item AS d ON d.item_id = ip.item_id
    WHERE d.item_class = 'Completed'
    GROUP BY ip.match_id, ip.participant_id
),
player_stat AS (
    SELECT m.patch, p.team_position AS role, p.win, s.metric_order, s.metric, s.lower_is_better, s.value
    FROM mart.v_valid_match AS m
    JOIN fact.match_participant AS p ON p.match_id = m.match_id
    LEFT JOIN first_item AS f ON f.match_id = p.match_id AND f.participant_id = p.participant_id
    CROSS APPLY (VALUES
        (1, 'Deaths',          1, CAST(p.deaths AS FLOAT)),
        (2, 'Kills + assists', 0, CAST(p.kills + p.assists AS FLOAT)),
        (3, 'CS / min',        0, p.creep_score * 60.0 / m.duration_s),
        (4, 'Damage / min',    0, p.damage_to_champions * 60.0 / m.duration_s),
        (5, 'Vision / min',    0, p.vision_score * 60.0 / m.duration_s),
        (6, 'First item (min)', 1, f.minutes)   -- NULL without a timeline or a completed item
    ) AS s (metric_order, metric, lower_is_better, value)
    WHERE p.team_position IS NOT NULL
      AND s.value IS NOT NULL
)
SELECT patch,
       role,
       metric_order,
       metric,
       CAST(lower_is_better AS BIT)                                          AS lower_is_better,
       AVG(CASE WHEN win = 1 THEN value END)                                 AS winners,
       AVG(CASE WHEN win = 0 THEN value END)                                 AS losers,
       AVG(CASE WHEN win = 1 THEN value END)
           / NULLIF(AVG(CASE WHEN win = 0 THEN value END), 0) - 1            AS gap,
       COUNT(*)                                                              AS players
FROM player_stat
GROUP BY patch, role, metric_order, metric, lower_is_better;
GO

-- Ban rate against win rate for every champion, all roles together.
CREATE OR ALTER VIEW mart.v_ban_vs_win
AS
SELECT patch,
       champion_id,
       MAX(champion_name)                          AS champion_name,
       SUM(games)                                  AS games,
       SUM(wins)                                   AS wins,
       CAST(SUM(wins) AS FLOAT) / SUM(games)       AS win_rate,
       MAX(ban_rate)                               AS ban_rate   -- the same in every role
FROM mart.v_champion_role_stats
GROUP BY patch, champion_id;
GO

-- Win rate of champions grouped by how often they are banned. win_rate_moe is the 95% margin
-- of error (games are player records, so it slightly understates it for champions who often
-- meet themselves in a match; that's rare).
CREATE OR ALTER VIEW mart.v_ban_band_win_rate
AS
SELECT b.patch,
       band.band_order,
       band.band,
       COUNT(*)                                          AS champions,
       SUM(b.games)                                      AS games,
       SUM(b.wins)                                       AS wins,
       CAST(SUM(b.wins) AS FLOAT) / SUM(b.games)         AS win_rate,
       1.96 * SQRT(0.25 / SUM(b.games))                  AS win_rate_moe
FROM mart.v_ban_vs_win AS b
CROSS APPLY (SELECT CASE WHEN b.ban_rate >= 0.10 THEN 1 WHEN b.ban_rate >= 0.03 THEN 2 ELSE 3 END AS band_order,
                    CASE WHEN b.ban_rate >= 0.10 THEN 'Banned in 10%+ of games'
                         WHEN b.ban_rate >= 0.03 THEN 'Banned in 3-10%'
                         ELSE 'Banned in under 3%' END AS band) AS band
GROUP BY b.patch, band.band_order, band.band;
GO

-- Blue side against red side. Every match has one winner, so the two win rates add up to 1.
CREATE OR ALTER VIEW mart.v_side_win_rate
AS
SELECT m.patch,
       CASE p.team_id WHEN 100 THEN 'Blue' ELSE 'Red' END                  AS side,
       COUNT(DISTINCT m.match_id)                                          AS games,
       COUNT(DISTINCT CASE WHEN p.win = 1 THEN m.match_id END)             AS wins,
       CAST(COUNT(DISTINCT CASE WHEN p.win = 1 THEN m.match_id END) AS FLOAT)
           / COUNT(DISTINCT m.match_id)                                    AS win_rate,
       1.96 * SQRT(0.25 / COUNT(DISTINCT m.match_id))                      AS win_rate_moe
FROM mart.v_valid_match AS m
JOIN fact.match_participant AS p ON p.match_id = m.match_id
GROUP BY m.patch, p.team_id;
GO

-- One row per team per valid match: did it win? The objective and gold-lead views join to this.
CREATE OR ALTER VIEW mart.v_team_result
AS
SELECT m.patch, p.match_id, p.team_id, MAX(CAST(p.win AS INT)) AS win
FROM mart.v_valid_match AS m
JOIN fact.match_participant AS p ON p.match_id = m.match_id
GROUP BY m.patch, p.match_id, p.team_id;
GO

-- What each objective is worth: how often the team that took it first went on to win, and how
-- often anyone took it at all. objective 'champion' is first blood.
CREATE OR ALTER VIEW mart.v_objective_win_rate
AS
WITH loaded AS (
    SELECT t.patch, COUNT(DISTINCT t.match_id) AS matches
    FROM mart.v_team_result AS t
    WHERE EXISTS (SELECT 1 FROM fact.team_objective AS o WHERE o.match_id = t.match_id)
    GROUP BY t.patch
)
SELECT t.patch,
       o.objective,
       COUNT(*)                                      AS games,
       SUM(t.win)                                    AS wins,
       CAST(SUM(t.win) AS FLOAT) / COUNT(*)          AS win_rate,
       1.96 * SQRT(0.25 / COUNT(*))                  AS win_rate_moe,
       CAST(COUNT(*) AS FLOAT) / MAX(l.matches)      AS taken_share
FROM mart.v_team_result AS t
JOIN fact.team_objective AS o ON o.match_id = t.match_id AND o.team_id = t.team_id AND o.is_first = 1
JOIN loaded AS l ON l.patch = t.patch
GROUP BY t.patch, o.objective;
GO

-- Win rate by how many of an objective a team took (capped, e.g. "4+ dragons"). Kills are left
-- out: a kill count says more about game length than about the objective.
CREATE OR ALTER VIEW mart.v_objective_count_win_rate
AS
SELECT t.patch,
       o.objective,
       c.taken,
       c.is_capped,
       COUNT(*)                                      AS games,
       SUM(t.win)                                    AS wins,
       CAST(SUM(t.win) AS FLOAT) / COUNT(*)          AS win_rate,
       1.96 * SQRT(0.25 / COUNT(*))                  AS win_rate_moe
FROM mart.v_team_result AS t
JOIN fact.team_objective AS o ON o.match_id = t.match_id AND o.team_id = t.team_id
CROSS APPLY (SELECT CASE o.objective WHEN 'dragon' THEN 4 WHEN 'horde' THEN 3 WHEN 'tower' THEN 9
                                     WHEN 'inhibitor' THEN 3 ELSE 2 END AS cap) AS k
CROSS APPLY (SELECT IIF(o.kills >= k.cap, k.cap, o.kills) AS taken,
                    IIF(o.kills >= k.cap, 1, 0)            AS is_capped) AS c
WHERE o.objective <> 'champion'
GROUP BY t.patch, o.objective, c.taken, c.is_capped;
GO

-- How often a team gold lead at 10, 15, 20 or 25 minutes turns into a win, by size of lead.
-- Only games still going at that minute count, and exact ties are left out.
CREATE OR ALTER VIEW mart.v_gold_lead_win_rate
AS
WITH team_gold AS (
    SELECT t.patch, t.match_id, t.team_id, t.win, f.minute, SUM(f.total_gold) AS gold
    FROM mart.v_team_result AS t
    JOIN fact.match_participant AS p ON p.match_id = t.match_id AND p.team_id = t.team_id
    JOIN fact.participant_frame AS f ON f.match_id = p.match_id AND f.participant_id = p.participant_id
    GROUP BY t.patch, t.match_id, t.team_id, t.win, f.minute
), lead AS (
    SELECT b.patch, b.minute,
           ABS(b.gold - r.gold)                                 AS gold_lead,
           IIF(b.gold > r.gold, b.win, r.win)                   AS leader_won
    FROM team_gold AS b
    JOIN team_gold AS r ON r.match_id = b.match_id AND r.minute = b.minute AND r.team_id = 200
    WHERE b.team_id = 100 AND b.gold <> r.gold
)
SELECT l.patch, l.minute, bd.band_min, bd.band_max,
       COUNT(*)                                              AS games,
       SUM(l.leader_won)                                     AS wins,
       CAST(SUM(l.leader_won) AS FLOAT) / COUNT(*)           AS win_rate,
       1.96 * SQRT(0.25 / COUNT(*))                          AS win_rate_moe
FROM lead AS l
CROSS APPLY (SELECT CASE WHEN l.gold_lead < 1000 THEN 0 WHEN l.gold_lead < 2000 THEN 1000
                         WHEN l.gold_lead < 3000 THEN 2000 WHEN l.gold_lead < 4000 THEN 3000
                         WHEN l.gold_lead < 6000 THEN 4000 ELSE 6000 END AS band_min) AS b0
CROSS APPLY (SELECT b0.band_min,
                    CASE b0.band_min WHEN 0 THEN 1000 WHEN 1000 THEN 2000 WHEN 2000 THEN 3000
                                     WHEN 3000 THEN 4000 WHEN 4000 THEN 6000 END AS band_max) AS bd
GROUP BY l.patch, l.minute, bd.band_min, bd.band_max;
GO

-- Which lane's lead matters most: when one laner is 1,000+ gold ahead of the opponent in the
-- same role at that minute, how often their team wins.
CREATE OR ALTER VIEW mart.v_lane_lead_win_rate
AS
WITH laner AS (
    SELECT t.patch, t.match_id, t.team_id, t.win, p.team_position AS role, f.minute, f.total_gold
    FROM mart.v_team_result AS t
    JOIN fact.match_participant AS p ON p.match_id = t.match_id AND p.team_id = t.team_id
    JOIN fact.participant_frame AS f ON f.match_id = p.match_id AND f.participant_id = p.participant_id
    WHERE p.team_position IS NOT NULL
)
SELECT a.patch, a.minute, a.role,
       COUNT(*)                                      AS games,
       SUM(a.win)                                    AS wins,
       CAST(SUM(a.win) AS FLOAT) / COUNT(*)          AS win_rate,
       1.96 * SQRT(0.25 / COUNT(*))                  AS win_rate_moe
FROM laner AS a
JOIN laner AS b ON b.match_id = a.match_id AND b.minute = a.minute AND b.role = a.role AND b.team_id <> a.team_id
WHERE a.total_gold - b.total_gold >= 1000
GROUP BY a.patch, a.minute, a.role;
GO
