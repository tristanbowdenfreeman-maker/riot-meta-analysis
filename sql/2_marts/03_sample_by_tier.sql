-- How the sample splits across ranks (tier of the player the match was sampled from).
CREATE OR REPLACE TABLE riot_mart.sample_by_tier AS
SELECT patch,
       IFNULL(sample_tier, 'UNKNOWN')                         AS sample_tier,
       COUNT(*)                                               AS matches,
       COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY patch)     AS share_of_matches
FROM riot_mart.valid_match
GROUP BY patch, sample_tier;
