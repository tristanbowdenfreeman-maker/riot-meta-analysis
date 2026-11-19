-- How often a team gold lead at 10, 15, 20 or 25 minutes turns into a win, by size of lead.
-- Only games still going at that minute count, and exact ties are left out.
WITH team_gold AS (
    SELECT t.patch, t.match_id, t.team_id, t.win, f.minute, SUM(f.total_gold) AS gold
    FROM {{ ref('team_result') }} AS t
    JOIN {{ ref('stg_fact_match_participant') }} AS p ON p.match_id = t.match_id AND p.team_id = t.team_id
    JOIN {{ ref('stg_fact_participant_frame') }} AS f ON f.match_id = p.match_id AND f.participant_id = p.participant_id
    GROUP BY t.patch, t.match_id, t.team_id, t.win, f.minute
),
lead AS (
    SELECT b.patch, b.minute,
           ABS(b.gold - r.gold)              AS gold_lead,
           IF(b.gold > r.gold, b.win, r.win) AS leader_won
    FROM team_gold AS b
    JOIN team_gold AS r ON r.match_id = b.match_id AND r.minute = b.minute AND r.team_id = 200
    WHERE b.team_id = 100 AND b.gold <> r.gold
),
banded AS (
    SELECT l.*,
           CASE WHEN gold_lead < 1000 THEN 0 WHEN gold_lead < 2000 THEN 1000
                WHEN gold_lead < 3000 THEN 2000 WHEN gold_lead < 4000 THEN 3000
                WHEN gold_lead < 6000 THEN 4000 ELSE 6000 END AS band_min
    FROM lead AS l
)
SELECT patch, minute, band_min,
       CASE band_min WHEN 0 THEN 1000 WHEN 1000 THEN 2000 WHEN 2000 THEN 3000
                     WHEN 3000 THEN 4000 WHEN 4000 THEN 6000 END AS band_max,   -- NULL: no upper bound
       COUNT(*)                         AS games,
       SUM(leader_won)                  AS wins,
       SUM(leader_won) / COUNT(*)       AS win_rate,
       1.96 * SQRT(0.25 / COUNT(*))     AS win_rate_moe
FROM banded
GROUP BY patch, minute, band_min, band_max
