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
