-- The dragon soul of each match, from the timeline's DRAGON_SOUL_GIVEN event: the first team to
-- take four dragons gets a soul named after the map's dragon type (Infernal, Ocean, ...).
-- One row per loaded timeline; team_id and soul are NULL when nobody got a soul.
IF OBJECT_ID(N'fact.dragon_soul') IS NULL
CREATE TABLE fact.dragon_soul (
    match_id      VARCHAR(30) NOT NULL CONSTRAINT PK_fact_dragon_soul PRIMARY KEY
                  CONSTRAINT FK_fact_dragon_soul_match REFERENCES fact.match (match_id),
    team_id       SMALLINT    NULL,
    soul          VARCHAR(20) NULL,
    timestamp_ms  INT         NULL
);
GO
