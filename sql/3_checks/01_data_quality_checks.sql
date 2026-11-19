-- Data-quality checks on the BigQuery tables. Each row is one check; failures = 0 means it passed.
-- checks.py adds the checks on the local store (raw JSON not loaded yet, failed downloads) and
-- `python -m riot_meta check` fails if any blocking check has failures. check_order keeps the
-- two lists in one order.
WITH participants AS (
    SELECT match_id, COUNT(*) AS players, COUNTIF(win) AS winners
    FROM riot_fact.match_participant
    GROUP BY match_id
),
timeline AS (
    SELECT t.match_id, m.duration_s
    FROM riot_fact.match_timeline AS t
    LEFT JOIN riot_fact.match AS m ON m.match_id = t.match_id
)
SELECT 1 AS check_order, 'every match has 10 participants' AS check_name, 1 AS is_blocking,
       (SELECT COUNT(*) FROM riot_fact.match AS m LEFT JOIN participants AS p ON p.match_id = m.match_id
        WHERE IFNULL(p.players, 0) <> 10) AS failures
UNION ALL
SELECT 2, 'every team has 5 players', 1,
       (SELECT COUNT(*) FROM (SELECT match_id, team_id FROM riot_fact.match_participant
                              GROUP BY match_id, team_id HAVING COUNT(*) <> 5))
UNION ALL
SELECT 3, 'exactly one winning team per valid match', 1,
       (SELECT COUNT(*) FROM participants AS p JOIN riot_mart.valid_match AS m ON m.match_id = p.match_id
        WHERE p.winners <> 5)
UNION ALL
SELECT 4, 'no more than 10 bans per match', 1,
       (SELECT COUNT(*) FROM (SELECT match_id FROM riot_fact.match_ban GROUP BY match_id HAVING COUNT(*) > 10))
UNION ALL
SELECT 7, 'champions missing from dim.champion (Data Dragon out of date?)', 1,
       (SELECT COUNT(DISTINCT p.champion_id) FROM riot_fact.match_participant AS p
        WHERE p.champion_id NOT IN (SELECT champion_id FROM riot_dim.champion))
UNION ALL
SELECT 9, 'loaded timelines with no purchases', 1,
       (SELECT COUNT(*) FROM timeline AS t
        WHERE t.match_id NOT IN (SELECT match_id FROM riot_fact.item_event WHERE event_type = 'ITEM_PURCHASED'))
UNION ALL
SELECT 10, 'matches with no objectives loaded', 1,
       (SELECT COUNT(*) FROM riot_fact.match AS m
        WHERE m.match_id NOT IN (SELECT match_id FROM riot_fact.team_objective))
UNION ALL
SELECT 11, 'objectives taken first by both teams', 1,
       (SELECT COUNT(*) FROM (SELECT match_id, objective FROM riot_fact.team_objective
                              GROUP BY match_id, objective HAVING COUNTIF(is_first) > 1))
UNION ALL
SELECT 12, 'timelines of 11+ minute games with no gold frames', 1,
       (SELECT COUNT(*) FROM timeline AS t
        WHERE t.duration_s >= 660
          AND t.match_id NOT IN (SELECT match_id FROM riot_fact.participant_frame))
UNION ALL
SELECT 13, 'loaded timelines with no skill level-ups', 0,
       (SELECT COUNT(*) FROM timeline AS t
        WHERE t.match_id NOT IN (SELECT match_id FROM riot_fact.participant_skills))
UNION ALL
SELECT 14, 'rune pages whose grid rows do not add up to the page games', 1,
       (SELECT COUNT(*) FROM (
            SELECT rp.patch, rp.champion_id, rp.role, rp.page_rank, r.tree_id, r.slot_index
            FROM riot_mart.champion_rune_picks AS rp
            JOIN riot_dim.rune AS r ON r.rune_id = rp.rune_id
            JOIN riot_mart.champion_rune_stats AS rs
              ON rs.patch = rp.patch AND rs.champion_id = rp.champion_id
             AND rs.role = rp.role AND rs.page_rank = rp.page_rank
            WHERE rp.is_primary_tree
            GROUP BY rp.patch, rp.champion_id, rp.role, rp.page_rank, r.tree_id, r.slot_index, rs.games
            HAVING SUM(rp.games) <> rs.games))
UNION ALL
SELECT 15, 'tier list roles whose games are not 2 per match', 0,
       (SELECT COUNT(*) FROM (
            SELECT r.patch, r.role FROM riot_mart.champion_role_stats AS r
            JOIN riot_mart.patch_summary AS t ON t.patch = r.patch
            GROUP BY r.patch, r.role, t.matches
            HAVING SUM(r.games) <> 2 * t.matches))
UNION ALL
-- Some completed items are never bought because an earlier item turns into them: Seraph's Embrace,
-- Muramana and Fimbulwinter (Archangel's Staff, Manamune and Winter's Approach once stacked),
-- Gunmetal Greaves (Berserker's Greaves' upgrade) and Diadem of Songs (the finished support quest).
-- The build stats count the purchase of the earlier item.
SELECT 16, 'completed items in the final inventory never bought in the timeline', 0,
       (SELECT COUNT(*) FROM riot_fact.participant_item AS i
        JOIN riot_fact.match_timeline AS t ON t.match_id = i.match_id
        JOIN riot_dim.item AS d ON d.item_id = i.item_id
        LEFT JOIN (SELECT DISTINCT match_id, participant_id, item_id FROM riot_mart.item_purchase) AS ip
          ON ip.match_id = i.match_id AND ip.participant_id = i.participant_id AND ip.item_id = i.item_id
        WHERE d.item_class = 'Completed'
          AND i.item_id NOT IN (3040, 3042, 3121, 3172, 2530)
          AND ip.item_id IS NULL)
UNION ALL
SELECT 17, 'valid matches without a timeline', 0,
       (SELECT COUNT(*) FROM riot_mart.valid_match AS m
        WHERE m.match_id NOT IN (SELECT match_id FROM riot_fact.match_timeline))
UNION ALL
SELECT 18, 'stat shards missing from dim.stat_shard', 0,
       (SELECT COUNT(DISTINCT s) FROM riot_fact.match_participant AS p
        CROSS JOIN UNNEST([p.shard_offense_id, p.shard_flex_id, p.shard_defense_id]) AS s
        WHERE s IS NOT NULL
          AND s NOT IN (SELECT shard_id FROM riot_dim.stat_shard))
UNION ALL
SELECT 19, 'items missing from dim.item', 0,
       (SELECT COUNT(DISTINCT i.item_id) FROM riot_fact.participant_item AS i
        WHERE i.item_id NOT IN (SELECT item_id FROM riot_dim.item))
UNION ALL
SELECT 20, 'valid-match players with no role assigned', 0,
       (SELECT COUNT(*) FROM riot_fact.match_participant AS p
        JOIN riot_mart.valid_match AS m ON m.match_id = p.match_id
        WHERE p.team_position IS NULL)
