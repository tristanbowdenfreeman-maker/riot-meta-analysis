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
