-- Staging layer: what the Python fetcher writes. Nothing here is transformed.

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

-- Work queue of match IDs to download. Makes the fetch resumable: a stopped run picks up the
-- remaining 'pending' rows next time.
IF OBJECT_ID(N'stg.match_queue') IS NULL
CREATE TABLE stg.match_queue (
    match_id      VARCHAR(30)  NOT NULL CONSTRAINT PK_stg_match_queue PRIMARY KEY,
    source_puuid  VARCHAR(100) NOT NULL,
    source_tier   VARCHAR(12)  NOT NULL,
    status        VARCHAR(10)  NOT NULL CONSTRAINT DF_stg_match_queue_status DEFAULT 'pending'
                  CONSTRAINT CK_stg_match_queue_status CHECK (status IN ('pending', 'done', 'skipped', 'failed')),
    attempts      TINYINT      NOT NULL CONSTRAINT DF_stg_match_queue_attempts DEFAULT 0,
    queued_at     DATETIME2(0) NOT NULL CONSTRAINT DF_stg_match_queue_queued DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(0) NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_stg_match_queue_status')
    CREATE INDEX IX_stg_match_queue_status ON stg.match_queue (status, queued_at);
GO

-- Raw match-v5 JSON. Stored GZIP-compressed (the same format as T-SQL COMPRESS), which keeps
-- 30,000 matches at a few hundred MB instead of several GB. Read it through stg.v_match_raw.
IF OBJECT_ID(N'stg.match_raw') IS NULL
CREATE TABLE stg.match_raw (
    match_id    VARCHAR(30)    NOT NULL CONSTRAINT PK_stg_match_raw PRIMARY KEY,
    payload_gz  VARBINARY(MAX) NOT NULL,
    fetched_at  DATETIME2(0)   NOT NULL CONSTRAINT DF_stg_match_raw_fetched DEFAULT SYSUTCDATETIME()
);
GO

CREATE OR ALTER VIEW stg.v_match_raw
AS
SELECT match_id,
       CAST(DECOMPRESS(payload_gz) AS NVARCHAR(MAX)) AS payload,
       fetched_at
FROM stg.match_raw;
GO

-- Data Dragon static files (champion.json, item.json, runesReforged.json, summoner.json).
IF OBJECT_ID(N'stg.ddragon_raw') IS NULL
CREATE TABLE stg.ddragon_raw (
    dataset          VARCHAR(20)   NOT NULL,
    ddragon_version  VARCHAR(20)   NOT NULL,
    payload          NVARCHAR(MAX) NOT NULL CONSTRAINT CK_stg_ddragon_raw_json CHECK (ISJSON(payload) = 1),
    loaded_at        DATETIME2(0)  NOT NULL CONSTRAINT DF_stg_ddragon_raw_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_stg_ddragon_raw PRIMARY KEY (dataset, ddragon_version)
);
GO
