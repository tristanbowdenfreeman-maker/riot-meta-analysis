-- Raw match-v5 timelines, one per fetched match, stored the same way as stg.match_raw.
-- The table is also the timeline fetch queue: a match in stg.match_raw with no row here, or a
-- 'pending' row, still needs its timeline. 'skipped' (404) and 'failed' rows have no payload.
IF OBJECT_ID(N'stg.timeline_raw') IS NULL
CREATE TABLE stg.timeline_raw (
    match_id    VARCHAR(30)    NOT NULL CONSTRAINT PK_stg_timeline_raw PRIMARY KEY,
    status      VARCHAR(10)    NOT NULL
                CONSTRAINT CK_stg_timeline_raw_status CHECK (status IN ('pending', 'done', 'skipped', 'failed')),
    attempts    TINYINT        NOT NULL CONSTRAINT DF_stg_timeline_raw_attempts DEFAULT 0,
    payload_gz  VARBINARY(MAX) NULL,
    fetched_at  DATETIME2(0)   NOT NULL CONSTRAINT DF_stg_timeline_raw_fetched DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(0)   NULL,
    CONSTRAINT CK_stg_timeline_raw_payload
        CHECK ((status = 'done' AND payload_gz IS NOT NULL) OR (status <> 'done' AND payload_gz IS NULL))
);
GO

CREATE OR ALTER VIEW stg.v_timeline_raw
AS
SELECT match_id,
       CAST(DECOMPRESS(payload_gz) AS NVARCHAR(MAX)) AS payload,
       fetched_at
FROM stg.timeline_raw
WHERE status = 'done';
GO
