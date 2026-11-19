-- Every rune on a rune page, for the rune grid: how often players on that page take it, and its
-- win rate. pick_share is out of the page's games, so each row of the grid adds up to 1.
CREATE OR REPLACE TABLE riot_mart.champion_rune_picks AS
SELECT pp.patch,
       pp.champion_id,
       pp.role,
       pp.page_rank,
       r.rune_id,
       r.tree_id,
       r.is_primary_tree,
       COUNT(*)                         AS games,
       COUNTIF(pp.win)                  AS wins,
       COUNTIF(pp.win) / COUNT(*)       AS win_rate,
       COUNT(*) / MAX(pp.page_games)    AS pick_share
FROM riot_mart.rune_page_player AS pp
JOIN riot_fact.participant_rune AS r ON r.match_id = pp.match_id AND r.participant_id = pp.participant_id
GROUP BY pp.patch, pp.champion_id, pp.role, pp.page_rank, r.rune_id, r.tree_id, r.is_primary_tree;
