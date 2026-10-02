-- Data-quality checks. Each row is one check; failures = 0 means it passed.
-- `python -m riot_meta check` prints this view and fails if any blocking check has failures.
CREATE OR ALTER VIEW etl.v_data_quality_checks
AS
SELECT 'every match has 10 participants' AS check_name, 1 AS is_blocking,
       (SELECT COUNT(*) FROM fact.match AS m
        WHERE (SELECT COUNT(*) FROM fact.match_participant AS p WHERE p.match_id = m.match_id) <> 10) AS failures
UNION ALL
SELECT 'every team has 5 players', 1,
       (SELECT COUNT(*) FROM (SELECT match_id, team_id FROM fact.match_participant
                              GROUP BY match_id, team_id HAVING COUNT(*) <> 5) AS x)
UNION ALL
SELECT 'exactly one winning team per valid match', 1,
       (SELECT COUNT(*) FROM (SELECT p.match_id FROM fact.match_participant AS p
                              JOIN mart.v_valid_match AS m ON m.match_id = p.match_id
                              GROUP BY p.match_id HAVING SUM(CAST(p.win AS INT)) <> 5) AS x)
UNION ALL
SELECT 'no more than 10 bans per match', 1,
       (SELECT COUNT(*) FROM (SELECT match_id FROM fact.match_ban GROUP BY match_id HAVING COUNT(*) > 10) AS x)
UNION ALL
SELECT 'raw matches not yet transformed', 1,
       (SELECT COUNT(*) FROM stg.match_raw AS r WHERE NOT EXISTS (SELECT 1 FROM fact.match AS m WHERE m.match_id = r.match_id))
UNION ALL
SELECT 'queue rows marked done without raw JSON', 1,
       (SELECT COUNT(*) FROM stg.match_queue AS q
        WHERE q.status = 'done' AND NOT EXISTS (SELECT 1 FROM stg.match_raw AS r WHERE r.match_id = q.match_id))
UNION ALL
SELECT 'champions missing from dim.champion (Data Dragon out of date?)', 1,
       (SELECT COUNT(DISTINCT p.champion_id) FROM fact.match_participant AS p
        WHERE NOT EXISTS (SELECT 1 FROM dim.champion AS c WHERE c.champion_id = p.champion_id))
UNION ALL
SELECT 'raw timelines not yet transformed', 1,
       (SELECT COUNT(*) FROM stg.timeline_raw AS r
        WHERE r.status = 'done'
          AND NOT EXISTS (SELECT 1 FROM fact.match_timeline AS t WHERE t.match_id = r.match_id))
UNION ALL
SELECT 'loaded timelines with no purchases', 1,
       (SELECT COUNT(*) FROM fact.match_timeline AS t
        WHERE NOT EXISTS (SELECT 1 FROM fact.item_event AS e
                          WHERE e.match_id = t.match_id AND e.event_type = 'ITEM_PURCHASED'))
UNION ALL
SELECT 'matches with no objectives loaded', 1,
       (SELECT COUNT(*) FROM fact.match AS m
        WHERE NOT EXISTS (SELECT 1 FROM fact.team_objective AS o WHERE o.match_id = m.match_id))
UNION ALL
SELECT 'objectives taken first by both teams', 1,
       (SELECT COUNT(*) FROM (SELECT match_id, objective FROM fact.team_objective
                              GROUP BY match_id, objective HAVING SUM(CAST(is_first AS INT)) > 1) AS x)
UNION ALL
SELECT 'timelines of 11+ minute games with no gold frames', 1,
       (SELECT COUNT(*) FROM fact.match_timeline AS t
        JOIN fact.match AS m ON m.match_id = t.match_id
        WHERE m.duration_s >= 660
          AND NOT EXISTS (SELECT 1 FROM fact.participant_frame AS f WHERE f.match_id = t.match_id))
UNION ALL
SELECT 'rune pages whose grid rows do not add up to the page games', 1,
       (SELECT COUNT(*) FROM (
            SELECT rp.patch, rp.champion_id, rp.role, rp.page_rank, r.tree_id, r.slot_index
            FROM mart.v_champion_rune_picks AS rp
            JOIN dim.rune AS r ON r.rune_id = rp.rune_id
            JOIN mart.v_champion_rune_stats AS rs
              ON rs.patch = rp.patch AND rs.champion_id = rp.champion_id
             AND rs.role = rp.role AND rs.page_rank = rp.page_rank
            WHERE rp.is_primary_tree = 1
            GROUP BY rp.patch, rp.champion_id, rp.role, rp.page_rank, r.tree_id, r.slot_index, rs.games
            HAVING SUM(rp.games) <> rs.games) AS x)
UNION ALL
SELECT 'tier list roles whose games are not 2 per match', 0,
       (SELECT COUNT(*) FROM (
            SELECT r.patch, r.role FROM mart.v_champion_role_stats AS r
            JOIN mart.v_patch_summary AS t ON t.patch = r.patch
            GROUP BY r.patch, r.role, t.matches
            HAVING SUM(r.games) <> 2 * t.matches) AS x)
UNION ALL
-- Some completed items are never bought because an earlier item turns into them: Seraph's Embrace,
-- Muramana and Fimbulwinter (Archangel's Staff, Manamune and Winter's Approach once stacked),
-- Gunmetal Greaves (Berserker's Greaves' upgrade) and Diadem of Songs (the finished support quest).
-- The build stats count the purchase of the earlier item.
SELECT 'completed items in the final inventory never bought in the timeline', 0,
       (SELECT COUNT(*) FROM fact.participant_item AS i
        JOIN fact.match_timeline AS t ON t.match_id = i.match_id
        JOIN dim.item AS d ON d.item_id = i.item_id
        WHERE d.item_class = 'Completed'
          AND i.item_id NOT IN (3040, 3042, 3121, 3172, 2530)
          AND NOT EXISTS (SELECT 1 FROM mart.v_item_purchase AS ip
                          WHERE ip.match_id = i.match_id AND ip.participant_id = i.participant_id
                            AND ip.item_id = i.item_id))
UNION ALL
SELECT 'valid matches without a timeline', 0,
       (SELECT COUNT(*) FROM mart.v_valid_match AS m
        WHERE NOT EXISTS (SELECT 1 FROM fact.match_timeline AS t WHERE t.match_id = m.match_id))
UNION ALL
SELECT 'stat shards missing from dim.stat_shard', 0,
       (SELECT COUNT(DISTINCT s.shard_id) FROM fact.match_participant AS p
        CROSS APPLY (VALUES (p.shard_offense_id), (p.shard_flex_id), (p.shard_defense_id)) AS s (shard_id)
        WHERE s.shard_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dim.stat_shard AS d WHERE d.shard_id = s.shard_id))
UNION ALL
SELECT 'items missing from dim.item', 0,
       (SELECT COUNT(DISTINCT i.item_id) FROM fact.participant_item AS i
        WHERE NOT EXISTS (SELECT 1 FROM dim.item AS d WHERE d.item_id = i.item_id))
UNION ALL
SELECT 'valid-match players with no role assigned', 0,
       (SELECT COUNT(*) FROM fact.match_participant AS p
        JOIN mart.v_valid_match AS m ON m.match_id = p.match_id
        WHERE p.team_position IS NULL)
UNION ALL
SELECT 'queue rows that failed to download', 0,
       (SELECT COUNT(*) FROM stg.match_queue WHERE status = 'failed')
UNION ALL
SELECT 'timelines that failed to download', 0,
       (SELECT COUNT(*) FROM stg.timeline_raw WHERE status = 'failed');
GO
