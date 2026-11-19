-- Ban rate against win rate for every champion, all roles together.
CREATE OR REPLACE TABLE riot_mart.ban_vs_win AS
SELECT patch,
       champion_id,
       MAX(champion_name)          AS champion_name,
       SUM(games)                  AS games,
       SUM(wins)                   AS wins,
       SUM(wins) / SUM(games)      AS win_rate,
       MAX(ban_rate)               AS ban_rate   -- the same in every role
FROM riot_mart.champion_role_stats
GROUP BY patch, champion_id;
