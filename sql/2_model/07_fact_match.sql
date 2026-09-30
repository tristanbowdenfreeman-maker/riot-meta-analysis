IF OBJECT_ID(N'fact.match') IS NULL
CREATE TABLE fact.match (
    match_id        VARCHAR(30)  NOT NULL CONSTRAINT PK_fact_match PRIMARY KEY,
    patch           VARCHAR(10)  NOT NULL,   -- major.minor of game_version, e.g. '15.19'
    game_version    VARCHAR(30)  NOT NULL,
    game_start_utc  DATETIME2(0) NOT NULL,
    duration_s      INT          NOT NULL,
    queue_id        INT          NOT NULL,   -- 420 = ranked solo/duo
    sample_tier     VARCHAR(12)  NULL,       -- tier of the player whose history the match came from
    is_remake       BIT          NOT NULL    -- games under 5 minutes
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fact_match_patch')
    CREATE INDEX IX_fact_match_patch ON fact.match (patch, queue_id, is_remake);
GO
