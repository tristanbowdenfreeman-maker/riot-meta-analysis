-- Rune pages: keystone plus primary/secondary tree combinations. page_rank 1 is the most played
-- (ties broken by id so the ranking is stable); the rune grid below covers pages 1 and 2.
SELECT m.patch,
       p.champion_id,
       p.team_position                  AS role,
       p.keystone_id,
       k.rune_name                      AS keystone_name,
       p.primary_tree_id,
       t1.tree_name                     AS primary_tree_name,
       p.secondary_tree_id,
       t2.tree_name                     AS secondary_tree_name,
       COUNT(*)                         AS games,
       COUNTIF(p.win)                   AS wins,
       COUNTIF(p.win) / COUNT(*)        AS win_rate,
       COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY m.patch, p.champion_id, p.team_position) AS pick_share,
       ROW_NUMBER() OVER (PARTITION BY m.patch, p.champion_id, p.team_position
                          ORDER BY COUNT(*) DESC, p.keystone_id, p.secondary_tree_id)  AS page_rank
FROM {{ ref('valid_match') }} AS m
JOIN {{ ref('stg_fact_match_participant') }} AS p ON p.match_id = m.match_id
LEFT JOIN {{ ref('stg_dim_rune') }} AS k       ON k.rune_id = p.keystone_id
LEFT JOIN {{ ref('stg_dim_rune_tree') }} AS t1 ON t1.tree_id = p.primary_tree_id
LEFT JOIN {{ ref('stg_dim_rune_tree') }} AS t2 ON t2.tree_id = p.secondary_tree_id
WHERE p.team_position IS NOT NULL
GROUP BY m.patch, p.champion_id, p.team_position, p.keystone_id, k.rune_name,
         p.primary_tree_id, t1.tree_name, p.secondary_tree_id, t2.tree_name
