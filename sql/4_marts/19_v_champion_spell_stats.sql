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
