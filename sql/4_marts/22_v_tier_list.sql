-- Tier list. Champions are ranked within each role by an adjusted win rate: their record plus
-- prior_games extra games at 50%, which pulls small samples towards 50%.
-- prior_games is estimated from the data (empirical Bayes, method of moments). Win rates differ
-- between champions partly for real and partly by chance; the chance part is known
-- (p(1 - p) / games), so subtracting it from the observed variance leaves the real variance.
-- The smaller the real differences, the more games a champion needs before its own record
-- outweighs 50%: prior_games = 0.25 / real variance. On 3,000 matches real win rates spread by
-- about 3 points either side of 50%, which gives about 255 games: 38-18 (67.9%) becomes 53.2%,
-- while 211-153 (58.0%) only falls to 54.7%.
-- win_rate_moe is the 95% margin of error of the raw win rate (1.96 standard errors).
-- Only champion/role pairs picked in at least 1% of matches and making up at least 10% of the
-- champion's games are ranked; the rest get no tier. Tiers are cut by rank within the role.
CREATE OR ALTER VIEW mart.v_tier_list
AS
WITH scored AS (
    SELECT r.*,
           CASE WHEN r.pick_rate >= 0.01 AND r.role_share >= 0.10 THEN 1 ELSE 0 END AS is_ranked
    FROM mart.v_champion_role_stats AS r
),
prior AS (
    -- The floor on the real variance caps prior_games at 2,500 if the chance part explains it all.
    SELECT patch,
           0.25 / GREATEST(VAR(win_rate) - AVG(win_rate * (1 - win_rate) / games), 0.0001) AS prior_games
    FROM scored
    WHERE is_ranked = 1
    GROUP BY patch
),
adjusted AS (
    SELECT s.*,
           p.prior_games,
           (s.wins + p.prior_games / 2) / (s.games + p.prior_games)  AS adjusted_win_rate,
           1.96 * SQRT(s.win_rate * (1 - s.win_rate) / s.games)     AS win_rate_moe
    FROM scored AS s
    JOIN prior AS p ON p.patch = s.patch
),
ranked AS (
    SELECT a.*,
           CASE WHEN a.is_ranked = 1
                THEN PERCENT_RANK() OVER (PARTITION BY a.patch, a.role, a.is_ranked
                                          ORDER BY a.adjusted_win_rate DESC) END AS role_percentile
    FROM adjusted AS a
)
SELECT patch, champion_id, champion_name, primary_class, role, games, wins, win_rate, win_rate_moe,
       pick_rate, ban_rate, role_share, kda, cs_per_min, damage_per_min, vision_per_min,
       role_kda, role_cs_per_min, role_damage_per_min, role_vision_per_min,
       prior_games, adjusted_win_rate, role_percentile,
       CASE
           WHEN role_percentile IS NULL THEN NULL
           WHEN role_percentile <= 0.05 THEN 'OP'   -- top 5%
           WHEN role_percentile <= 0.20 THEN '1'    -- next 15%
           WHEN role_percentile <= 0.45 THEN '2'    -- next 25%
           WHEN role_percentile <= 0.75 THEN '3'    -- next 30%
           WHEN role_percentile <= 0.92 THEN '4'    -- next 17%
           ELSE '5'                                  -- bottom 8%
       END AS tier
FROM ranked;
GO
