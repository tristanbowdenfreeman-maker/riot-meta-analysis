-- Denominators: pick and ban rates are shares of all valid matches in the patch.
CREATE OR ALTER VIEW mart.v_patch_summary
AS
SELECT patch,
       COUNT(*)                   AS matches,
       COUNT(*) * 10              AS player_records,
       MIN(game_start_utc)        AS first_game_utc,
       MAX(game_start_utc)        AS last_game_utc,
       AVG(duration_s) / 60.0     AS avg_duration_min
FROM mart.v_valid_match
GROUP BY patch;
GO
