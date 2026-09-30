-- The size of the data behind each patch, for the headline figures on the site.
-- Each count is a seek on the match_id key, so this stays cheap as the tables grow.
CREATE OR ALTER VIEW mart.v_data_volume
AS
SELECT m.patch,
       COUNT(*)                                                                    AS matches,
       COUNT(*) * 10                                                               AS player_records,
       SUM(t.timelines)                                                            AS timelines,
       SUM(e.item_events)                                                          AS item_events,
       SUM(r.rune_choices)                                                         AS rune_choices,
       SUM(b.bans)                                                                 AS bans,
       (SELECT COUNT(*) FROM stg.player)                                           AS ladder_players,
       SUM(DATALENGTH(mr.payload_gz) + ISNULL(DATALENGTH(tr.payload_gz), 0)) / 1048576.0 AS raw_json_mb,
       SUM(o.objectives)                                                           AS objective_rows,
       SUM(f.gold_frames)                                                          AS gold_frames,
       -- Every fact row behind the patch: matches, players, inventories, runes, bans, item events,
       -- team objectives and gold frames.
       COUNT(*) * 11 + SUM(i.inventory_items) + SUM(r.rune_choices) + SUM(b.bans) + SUM(e.item_events)
           + SUM(o.objectives) + SUM(f.gold_frames)                                AS fact_rows,
       (SELECT COUNT(*) FROM sys.views WHERE schema_id = SCHEMA_ID(N'mart'))       AS mart_views
FROM mart.v_valid_match AS m
JOIN stg.match_raw AS mr ON mr.match_id = m.match_id
LEFT JOIN stg.timeline_raw AS tr ON tr.match_id = m.match_id
OUTER APPLY (SELECT COUNT(*) AS timelines FROM fact.match_timeline AS x WHERE x.match_id = m.match_id) AS t
OUTER APPLY (SELECT COUNT(*) AS item_events FROM fact.item_event AS x WHERE x.match_id = m.match_id) AS e
OUTER APPLY (SELECT COUNT(*) AS rune_choices FROM fact.participant_rune AS x WHERE x.match_id = m.match_id) AS r
OUTER APPLY (SELECT COUNT(*) AS bans FROM fact.match_ban AS x WHERE x.match_id = m.match_id) AS b
OUTER APPLY (SELECT COUNT(*) AS inventory_items FROM fact.participant_item AS x WHERE x.match_id = m.match_id) AS i
OUTER APPLY (SELECT COUNT(*) AS objectives FROM fact.team_objective AS x WHERE x.match_id = m.match_id) AS o
OUTER APPLY (SELECT COUNT(*) AS gold_frames FROM fact.participant_frame AS x WHERE x.match_id = m.match_id) AS f
GROUP BY m.patch;
GO
