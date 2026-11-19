-- Player records in valid matches whose timeline has been loaded: the base for every
-- build-order mart, so shares are out of players we can actually see the purchases of.
SELECT m.patch, p.match_id, p.participant_id, p.champion_id, p.team_position AS role, p.win
FROM {{ ref('valid_match') }} AS m
JOIN {{ ref('stg_fact_match_timeline') }} AS t ON t.match_id = m.match_id
JOIN {{ ref('stg_fact_match_participant') }} AS p ON p.match_id = m.match_id
WHERE p.team_position IS NOT NULL
