-- Denominators: pick and ban rates are shares of all valid matches in the patch.
SELECT patch,
       COUNT(*)                                AS matches,
       COUNT(*) * 10                           AS player_records,
       MIN(game_start_utc)                     AS first_game_utc,
       MAX(game_start_utc)                     AS last_game_utc,
       DIV(SUM(duration_s), COUNT(*)) / 60.0   AS avg_duration_min   -- whole seconds, then minutes
FROM {{ ref('valid_match') }}
GROUP BY patch
