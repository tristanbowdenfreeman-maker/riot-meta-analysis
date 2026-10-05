-- Matches that count towards the stats: EUW ranked solo/duo, no remakes, on the live patch.
-- EUW players' histories also hold games on other European servers (EUN1_, TR1_, RU_), which are
-- out of scope. A new patch being collected stays out of every view until it goes live (etl.patch).
-- Games stopped by the server (e.g. endOfGameResult 'Abort_AntiCheatExit') have no winner and are left out.
CREATE OR ALTER VIEW mart.v_valid_match
AS
SELECT m.match_id, m.patch, m.game_start_utc, m.duration_s, m.sample_tier
FROM fact.match AS m
WHERE m.queue_id = 420
  AND m.is_remake = 0
  AND m.match_id LIKE 'EUW1[_]%'
  AND m.patch IN (SELECT patch FROM etl.patch WHERE status = 'live')
  AND EXISTS (SELECT 1 FROM fact.match_participant AS p WHERE p.match_id = m.match_id AND p.win = 1);
GO
