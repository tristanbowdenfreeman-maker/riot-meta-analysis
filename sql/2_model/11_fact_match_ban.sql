IF OBJECT_ID(N'fact.match_ban') IS NULL
CREATE TABLE fact.match_ban (
    match_id     VARCHAR(30) NOT NULL CONSTRAINT FK_fact_match_ban_match REFERENCES fact.match (match_id),
    team_id      SMALLINT    NOT NULL,
    pick_turn    TINYINT     NOT NULL,
    champion_id  INT         NOT NULL,
    CONSTRAINT PK_fact_match_ban PRIMARY KEY (match_id, team_id, pick_turn)
);
GO
