-- Team objectives from match-v5 info.teams[].objectives: which team took each one first, and
-- how many each took. objective is Riot's key: champion (kills, so first = first blood), tower,
-- dragon, horde (void grubs), riftHerald, baron, inhibitor, and any new ones Riot adds.
-- Key: match_id, team_id, objective.
CREATE TABLE IF NOT EXISTS riot_fact.team_objective (
    match_id   STRING NOT NULL,
    team_id    INT64  NOT NULL,
    objective  STRING NOT NULL,
    is_first   BOOL   NOT NULL,
    kills      INT64  NOT NULL
);
