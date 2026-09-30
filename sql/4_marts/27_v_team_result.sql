-- One row per team per valid match: did it win? The objective and gold-lead views join to this.
CREATE OR ALTER VIEW mart.v_team_result
AS
SELECT m.patch, p.match_id, p.team_id, MAX(CAST(p.win AS INT)) AS win
FROM mart.v_valid_match AS m
JOIN fact.match_participant AS p ON p.match_id = m.match_id
GROUP BY m.patch, p.match_id, p.team_id;
GO
