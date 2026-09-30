-- One row per match whose timeline has been parsed. Build-order stats only use these matches,
-- so a missing timeline can't be mistaken for a player who bought nothing.
IF OBJECT_ID(N'fact.match_timeline') IS NULL
CREATE TABLE fact.match_timeline (
    match_id   VARCHAR(30)  NOT NULL CONSTRAINT PK_fact_match_timeline PRIMARY KEY
               CONSTRAINT FK_fact_match_timeline_match REFERENCES fact.match (match_id),
    loaded_at  DATETIME2(0) NOT NULL CONSTRAINT DF_fact_match_timeline_loaded DEFAULT SYSUTCDATETIME()
);
GO
