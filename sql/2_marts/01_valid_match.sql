-- Matches that count towards the stats: EUW ranked solo/duo, no remakes, on the live patch.
-- EUW players' histories also hold games on other European servers (EUN1_, TR1_, RU_), which are
-- out of scope. A new patch being collected stays out of every mart until it goes live (riot_etl.patch).
-- Games stopped by the server (e.g. endOfGameResult 'Abort_AntiCheatExit') have no winner and are left out.
CREATE OR REPLACE TABLE riot_mart.valid_match AS
SELECT m.match_id, m.patch, m.game_start_utc, m.duration_s, m.sample_tier
FROM riot_fact.match AS m
WHERE m.queue_id = 420
  AND NOT m.is_remake
  AND STARTS_WITH(m.match_id, 'EUW1_')
  AND m.patch IN (SELECT p.patch FROM riot_etl.patch AS p WHERE p.status = 'live')
  AND m.match_id IN (SELECT match_id FROM riot_fact.match_participant WHERE win);
