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

    CREATE TABLE #batch (
        match_id  VARCHAR(30)   NOT NULL PRIMARY KEY,
        payload   NVARCHAR(MAX) NOT NULL
    );

    WHILE 1 = 1
    BEGIN
        TRUNCATE TABLE #batch;

        INSERT INTO #batch (match_id, payload)
        SELECT TOP (@batch_size) r.match_id, r.payload
        FROM stg.v_timeline_raw AS r
        JOIN fact.match_timeline AS t ON t.match_id = r.match_id
        JOIN fact.match AS m ON m.match_id = r.match_id
        WHERE m.duration_s >= 660
          AND NOT EXISTS (SELECT 1 FROM fact.participant_frame AS f WHERE f.match_id = r.match_id)
        ORDER BY r.match_id;

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
