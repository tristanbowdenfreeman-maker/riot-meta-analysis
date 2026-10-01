-- The patches being collected, at most one of each status:
--   live       : the patch the website shows
--   collecting : a newer patch, filling up in the background until it has a full sample
--   retired    : replaced; its data is being deleted (etl.usp_delete_retired_patches)
-- The website keeps showing the live patch until the new one has a full sample, so it never shows
-- a patch on a handful of games.
IF OBJECT_ID(N'etl.patch') IS NULL
CREATE TABLE etl.patch (
    patch           VARCHAR(10)  NOT NULL CONSTRAINT PK_etl_patch PRIMARY KEY,  -- e.g. '16.19'
    status          VARCHAR(10)  NOT NULL
                    CONSTRAINT CK_etl_patch_status CHECK (status IN ('collecting', 'live', 'retired')),
    started_utc     DATETIME2(0) NOT NULL,  -- only matches played since then are queued
    live_since_utc  DATETIME2(0) NULL
);
GO

-- A database that already holds matches: its patch is the live one.
IF NOT EXISTS (SELECT 1 FROM etl.patch) AND EXISTS (SELECT 1 FROM fact.match)
    INSERT INTO etl.patch (patch, status, started_utc, live_since_utc)
    SELECT TOP 1 patch, 'live', CAST(CAST(MIN(game_start_utc) AS DATE) AS DATETIME2(0)), SYSUTCDATETIME()
    FROM fact.match
    GROUP BY patch
    ORDER BY COUNT(*) DESC;
GO
