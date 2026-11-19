-- How the sample splits across ranks (tier of the player the match was sampled from).
SELECT patch,
       IFNULL(sample_tier, 'UNKNOWN')                         AS sample_tier,
       COUNT(*)                                               AS matches,
       COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY patch)     AS share_of_matches
FROM {{ ref('valid_match') }}
GROUP BY patch, sample_tier
