-- One row per team per valid match: did it win (1 or 0)? The objective and gold-lead marts join to this.
CREATE OR REPLACE TABLE riot_mart.team_result AS
SELECT m.patch, p.match_id, p.team_id, MAX(CAST(p.win AS INT64)) AS win
FROM riot_mart.valid_match AS m
JOIN riot_fact.match_participant AS p ON p.match_id = m.match_id
GROUP BY m.patch, p.match_id, p.team_id;
