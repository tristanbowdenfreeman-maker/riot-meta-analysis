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
