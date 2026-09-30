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
