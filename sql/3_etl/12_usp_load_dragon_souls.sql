-- Raw timelines -> fact.dragon_soul, for timelines already in fact.match_timeline.
CREATE OR ALTER PROCEDURE etl.usp_load_dragon_souls
    @batch_size INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch_rows INT, @total_rows INT = 0;

    -- One loader at a time: a second caller (the collector during a long backfill) waits here
    -- instead of picking the same match IDs.
    EXEC sp_getapplock @Resource = N'etl.usp_load_dragon_souls', @LockMode = 'Exclusive',
                       @LockOwner = 'Session', @LockTimeout = -1;

    CREATE TABLE #ids (match_id VARCHAR(30) NOT NULL PRIMARY KEY);
    CREATE TABLE #batch (
        match_id  VARCHAR(30)   NOT NULL PRIMARY KEY,
        payload   NVARCHAR(MAX) NOT NULL
    );

    WHILE 1 = 1
    BEGIN
        TRUNCATE TABLE #batch;

        -- Pick the match IDs into #ids first, then decompress only those timelines. In one
        -- statement SQL Server can decompress every stored timeline to find the next 100.
        TRUNCATE TABLE #ids;
        INSERT INTO #ids (match_id)
        SELECT TOP (@batch_size) t.match_id
        FROM fact.match_timeline AS t
        WHERE NOT EXISTS (SELECT 1 FROM fact.dragon_soul AS d WHERE d.match_id = t.match_id)
        ORDER BY t.match_id;

        INSERT INTO #batch (match_id, payload)
        SELECT i.match_id, CAST(DECOMPRESS(r.payload_gz) AS NVARCHAR(MAX))
        FROM #ids AS i
        JOIN stg.timeline_raw AS r ON r.match_id = i.match_id
        WHERE r.status = 'done';

        SET @batch_rows = @@ROWCOUNT;
        IF @batch_rows = 0 BREAK;

        -- info.frames[].events[]: {"type": "DRAGON_SOUL_GIVEN", "teamId": 100, "name": "Infernal", ...}
        -- teamId 0 is the map turning into the soul's terrain, not a team getting it.
        INSERT INTO fact.dragon_soul (match_id, team_id, soul, timestamp_ms)
        SELECT b.match_id, s.teamId, s.name, s.[timestamp]
        FROM #batch AS b
        OUTER APPLY (
            SELECT TOP 1 e.teamId, e.name, e.[timestamp]
            FROM OPENJSON(b.payload, '$.info.frames') AS f
            CROSS APPLY OPENJSON(f.value, '$.events') WITH (
                type         VARCHAR(40),
                teamId       SMALLINT,
                name         VARCHAR(20),
                [timestamp]  INT
            ) AS e
            WHERE CHARINDEX('DRAGON_SOUL_GIVEN', f.value) > 0   -- skip parsing frames without one
              AND e.type = 'DRAGON_SOUL_GIVEN' AND e.teamId IN (100, 200)
            ORDER BY e.[timestamp]
        ) AS s;

        SET @total_rows += @batch_rows;
    END;

    EXEC sp_releaseapplock @Resource = N'etl.usp_load_dragon_souls', @LockOwner = 'Session';
    SELECT @total_rows AS timelines_loaded;
END;
GO
