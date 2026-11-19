-- Stat shards on each rune page, by row (1 = offense, 2 = flex, 3 = defense).
CREATE OR REPLACE TABLE riot_mart.champion_shard_picks AS
SELECT pp.patch,
       pp.champion_id,
       pp.role,
       pp.page_rank,
       s.shard_row,
       s.shard_id,
       COUNT(*)                         AS games,
       COUNTIF(pp.win)                  AS wins,
       COUNTIF(pp.win) / COUNT(*)       AS win_rate,
       COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY pp.patch, pp.champion_id, pp.role, pp.page_rank, s.shard_row)
                                        AS pick_share
FROM riot_mart.rune_page_player AS pp
CROSS JOIN UNNEST([
    STRUCT(1 AS shard_row, pp.shard_offense_id AS shard_id),
    STRUCT(2, pp.shard_flex_id),
    STRUCT(3, pp.shard_defense_id)
]) AS s
WHERE s.shard_id IS NOT NULL
GROUP BY pp.patch, pp.champion_id, pp.role, pp.page_rank, s.shard_row, s.shard_id;
