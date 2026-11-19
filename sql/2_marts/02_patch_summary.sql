-- Denominators: pick and ban rates are shares of all valid matches in the patch.
CREATE OR REPLACE TABLE riot_mart.patch_summary AS
SELECT patch,
       COUNT(*)                                AS matches,
       COUNT(*) * 10                           AS player_records,
       MIN(game_start_utc)                     AS first_game_utc,
       MAX(game_start_utc)                     AS last_game_utc,
       DIV(SUM(duration_s), COUNT(*)) / 60.0   AS avg_duration_min   -- whole seconds, then minutes
FROM riot_mart.valid_match
GROUP BY patch;
