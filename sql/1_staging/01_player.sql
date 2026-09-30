-- Ranked players found through the league-exp-v4 endpoint.
IF OBJECT_ID(N'stg.player') IS NULL
CREATE TABLE stg.player (
    puuid                 VARCHAR(100) NOT NULL CONSTRAINT PK_stg_player PRIMARY KEY,
    tier                  VARCHAR(12)  NOT NULL,
    division              VARCHAR(3)   NOT NULL,
    league_points         INT          NOT NULL,
    wins                  INT          NOT NULL,
    losses                INT          NOT NULL,
    discovered_at         DATETIME2(0) NOT NULL CONSTRAINT DF_stg_player_discovered DEFAULT SYSUTCDATETIME(),
    match_ids_fetched_at  DATETIME2(0) NULL
);
GO
