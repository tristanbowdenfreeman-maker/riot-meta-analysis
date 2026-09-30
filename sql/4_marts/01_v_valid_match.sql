-- Matches that count towards the stats: EUW ranked solo/duo, no remakes. EUW players' histories
-- also hold games on other European servers (EUN1_, TR1_, RU_), which are out of scope.
CREATE OR ALTER VIEW mart.v_valid_match
AS
SELECT match_id, patch, game_start_utc, duration_s, sample_tier
FROM fact.match
WHERE queue_id = 420
  AND is_remake = 0
  AND match_id LIKE 'EUW1[_]%';
GO
