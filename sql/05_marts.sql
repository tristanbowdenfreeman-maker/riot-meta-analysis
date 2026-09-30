-- Reporting views. Every view is per patch and excludes remakes and non-solo/duo games.
-- The dashboard reads these (via the Parquet export) and applies its own minimum-games cutoff.

-- Matches that count towards the stats.
CREATE OR ALTER VIEW mart.v_valid_match
AS
SELECT match_id, patch, game_start_utc, duration_s, sample_tier
FROM fact.match
WHERE queue_id = 420
  AND is_remake = 0;
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

-- Pairs of completed items finished together, the closest thing to a "core build" without timelines.
CREATE OR ALTER VIEW mart.v_champion_item_pairs
AS
WITH owned AS (
    SELECT DISTINCT m.patch, p.match_id, p.participant_id, p.champion_id, p.team_position AS role, p.win, i.item_id
    FROM mart.v_valid_match AS m
    JOIN fact.match_participant AS p ON p.match_id = m.match_id
    JOIN fact.participant_item AS i ON i.match_id = p.match_id AND i.participant_id = p.participant_id
    JOIN dim.item AS d ON d.item_id = i.item_id
    WHERE p.team_position IS NOT NULL
      AND d.item_class = 'Completed'
)
SELECT a.patch,
       a.champion_id,
       a.role,
       a.item_id                                            AS item1_id,
       d1.item_name                                         AS item1_name,
       b.item_id                                            AS item2_id,
       d2.item_name                                         AS item2_name,
       COUNT(*)                                             AS games,
       SUM(CAST(a.win AS INT))                              AS wins,
       CAST(SUM(CAST(a.win AS INT)) AS FLOAT) / COUNT(*)    AS win_rate
FROM owned AS a
JOIN owned AS b
  ON b.match_id = a.match_id
 AND b.participant_id = a.participant_id
 AND b.item_id > a.item_id                -- each pair once, never an item with itself
JOIN dim.item AS d1 ON d1.item_id = a.item_id
JOIN dim.item AS d2 ON d2.item_id = b.item_id
GROUP BY a.patch, a.champion_id, a.role, a.item_id, d1.item_name, b.item_id, d2.item_name;
GO

-- Keystone plus primary/secondary tree combinations.
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
           / SUM(COUNT(*)) OVER (PARTITION BY m.patch, p.champion_id, p.team_position) AS pick_share
FROM mart.v_valid_match AS m
JOIN fact.match_participant AS p ON p.match_id = m.match_id
LEFT JOIN dim.rune AS k       ON k.rune_id = p.keystone_id
LEFT JOIN dim.rune_tree AS t1 ON t1.tree_id = p.primary_tree_id
LEFT JOIN dim.rune_tree AS t2 ON t2.tree_id = p.secondary_tree_id
WHERE p.team_position IS NOT NULL
GROUP BY m.patch, p.champion_id, p.team_position, p.keystone_id, k.rune_name,
         p.primary_tree_id, t1.tree_name, p.secondary_tree_id, t2.tree_name;
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
