-- How the sample splits across ranks (tier of the player the match was sampled from).
CREATE OR ALTER VIEW mart.v_sample_by_tier
AS
SELECT m.patch,
       ISNULL(m.sample_tier, 'UNKNOWN')                                  AS sample_tier,
       COUNT(*)                                                          AS matches,
       CAST(COUNT(*) AS FLOAT) / SUM(COUNT(*)) OVER (PARTITION BY m.patch) AS share_of_matches
FROM mart.v_valid_match AS m
GROUP BY m.patch, m.sample_tier;
GO
