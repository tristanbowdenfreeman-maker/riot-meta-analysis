-- Summoner spell pairs. Flash on D and on F count as the same pair.
WITH spells AS (
    SELECT m.patch, p.champion_id, p.team_position AS role, p.win,
           LEAST(p.summoner1_id, p.summoner2_id)    AS spell_a_id,
           GREATEST(p.summoner1_id, p.summoner2_id) AS spell_b_id
    FROM {{ ref('valid_match') }} AS m
    JOIN {{ ref('stg_fact_match_participant') }} AS p ON p.match_id = m.match_id
    WHERE p.team_position IS NOT NULL
)
SELECT s.patch,
       s.champion_id,
       s.role,
       s.spell_a_id,
       sa.spell_name                    AS spell_a_name,
       s.spell_b_id,
       sb.spell_name                    AS spell_b_name,
       COUNT(*)                         AS games,
       COUNTIF(s.win)                   AS wins,
       COUNTIF(s.win) / COUNT(*)        AS win_rate,
       COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY s.patch, s.champion_id, s.role) AS pick_share
FROM spells AS s
LEFT JOIN {{ ref('stg_dim_summoner_spell') }} AS sa ON sa.spell_id = s.spell_a_id
LEFT JOIN {{ ref('stg_dim_summoner_spell') }} AS sb ON sb.spell_id = s.spell_b_id
GROUP BY s.patch, s.champion_id, s.role, s.spell_a_id, sa.spell_name, s.spell_b_id, sb.spell_name
