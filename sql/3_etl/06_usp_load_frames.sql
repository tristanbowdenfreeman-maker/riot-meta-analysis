-- Raw timelines -> fact.participant_frame, for timelines already in fact.match_timeline.
-- Only games of 11+ minutes have a minute-10 frame; shorter ones are remakes or early
-- surrenders and are skipped, so every match picked up here gets rows.
CREATE OR ALTER PROCEDURE etl.usp_load_frames
    @batch_size INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch_rows INT, @total_rows INT = 0;

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
        JOIN fact.match AS m ON m.match_id = t.match_id
        WHERE m.duration_s >= 660
          AND NOT EXISTS (SELECT 1 FROM fact.participant_frame AS f WHERE f.match_id = t.match_id)
        ORDER BY t.match_id;

        INSERT INTO #batch (match_id, payload)
        SELECT i.match_id, CAST(DECOMPRESS(r.payload_gz) AS NVARCHAR(MAX))
        FROM #ids AS i
        JOIN stg.timeline_raw AS r ON r.match_id = i.match_id
        WHERE r.status = 'done';

        SET @batch_rows = @@ROWCOUNT;
        IF @batch_rows = 0 BREAK;

        -- info.frames[n].participantFrames: {"1": {"totalGold": 7397, "xp": 9690, ...}, "2": ...}
        INSERT INTO fact.participant_frame (match_id, minute, participant_id, total_gold, xp, creep_score)
        SELECT b.match_id, CAST(f.[key] AS TINYINT), pf.participantId, pf.totalGold, pf.xp,
               pf.minionsKilled + pf.jungleMinionsKilled
        FROM #batch AS b
        CROSS APPLY OPENJSON(b.payload, '$.info.frames') AS f
        CROSS APPLY OPENJSON(f.value, '$.participantFrames') AS p
        CROSS APPLY OPENJSON(p.value) WITH (
            participantId        TINYINT,
            totalGold            INT,
            xp                   INT,
            minionsKilled        INT,
            jungleMinionsKilled  INT
        ) AS pf
        WHERE f.[key] IN ('10', '15', '20', '25')
          AND pf.participantId BETWEEN 1 AND 10;

        IF @@ROWCOUNT = 0 BREAK;
        SET @total_rows += @batch_rows;
    END;

    SELECT @total_rows AS timelines_loaded;
END;
GO
