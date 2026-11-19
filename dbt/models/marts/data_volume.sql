-- The size of the data behind each patch, for the headline figures on the site.
-- ladder_players, raw_json_mb and mart_views come from outside BigQuery (the local store and the
-- list of marts), so export.py fills them in.
WITH fact_row AS (
    SELECT 'timeline' AS kind, match_id FROM {{ ref('stg_fact_match_timeline') }}
    UNION ALL SELECT 'item_event', match_id FROM {{ ref('stg_fact_item_event') }}
    UNION ALL SELECT 'rune', match_id FROM {{ ref('stg_fact_participant_rune') }}
    UNION ALL SELECT 'ban', match_id FROM {{ ref('stg_fact_match_ban') }}
    UNION ALL SELECT 'item', match_id FROM {{ ref('stg_fact_participant_item') }}
    UNION ALL SELECT 'objective', match_id FROM {{ ref('stg_fact_team_objective') }}
    UNION ALL SELECT 'frame', match_id FROM {{ ref('stg_fact_participant_frame') }}
),
per_patch AS (
    SELECT m.patch,
           COUNTIF(f.kind = 'timeline')   AS timelines,
           COUNTIF(f.kind = 'item_event') AS item_events,
           COUNTIF(f.kind = 'rune')       AS rune_choices,
           COUNTIF(f.kind = 'ban')        AS bans,
           COUNTIF(f.kind = 'item')       AS inventory_items,
           COUNTIF(f.kind = 'objective')  AS objective_rows,
           COUNTIF(f.kind = 'frame')      AS gold_frames
    FROM fact_row AS f
    JOIN {{ ref('valid_match') }} AS m ON m.match_id = f.match_id
    GROUP BY m.patch
)
SELECT s.patch,
       s.matches,
       s.matches * 10                AS player_records,
       p.timelines,
       p.item_events,
       p.rune_choices,
       p.bans,
       CAST(NULL AS INT64)           AS ladder_players,
       CAST(NULL AS FLOAT64)         AS raw_json_mb,
       p.objective_rows,
       p.gold_frames,
       -- Every fact row behind the patch: matches, players, inventories, runes, bans, item events,
       -- team objectives and gold frames.
       s.matches * 11 + p.inventory_items + p.rune_choices + p.bans + p.item_events
           + p.objective_rows + p.gold_frames AS fact_rows,
       CAST(NULL AS INT64)           AS mart_views
FROM {{ ref('patch_summary') }} AS s
LEFT JOIN per_patch AS p ON p.patch = s.patch
