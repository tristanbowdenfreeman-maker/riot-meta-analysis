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
