-- One row per team per valid match: did it win (1 or 0)? The objective and gold-lead marts join to this.
SELECT m.patch, p.match_id, p.team_id, MAX(CAST(p.win AS INT64)) AS win
FROM {{ ref('valid_match') }} AS m
JOIN {{ ref('stg_fact_match_participant') }} AS p ON p.match_id = m.match_id
GROUP BY m.patch, p.match_id, p.team_id
