-- Team objectives from match-v5 info.teams[].objectives: which team took each one first, and
-- how many each took. objective is Riot's key: champion (kills, so first = first blood), tower,
-- dragon, horde (void grubs), riftHerald, baron, inhibitor, and any new ones Riot adds.
IF OBJECT_ID(N'fact.team_objective') IS NULL
CREATE TABLE fact.team_objective (
    match_id   VARCHAR(30) NOT NULL CONSTRAINT FK_fact_team_objective_match REFERENCES fact.match (match_id),
    team_id    SMALLINT    NOT NULL,
    objective  VARCHAR(20) NOT NULL,
    is_first   BIT         NOT NULL,
    kills      SMALLINT    NOT NULL,
    CONSTRAINT PK_fact_team_objective PRIMARY KEY (match_id, team_id, objective)
);
GO
