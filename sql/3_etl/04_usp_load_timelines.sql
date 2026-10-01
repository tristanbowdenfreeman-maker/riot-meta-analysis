-- Raw timelines -> fact.item_event. Incremental like usp_load_matches, and only for matches
-- already in fact.match. Timelines are ~0.5 MB of JSON each, hence the smaller batches.
CREATE OR ALTER PROCEDURE etl.usp_load_timelines
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
        WHERE EXISTS (SELECT 1 FROM fact.match AS m WHERE m.match_id = r.match_id)
          AND NOT EXISTS (SELECT 1 FROM fact.match_timeline AS t WHERE t.match_id = r.match_id)
        ORDER BY r.match_id;

        SET @batch_rows = @@ROWCOUNT;
        IF @batch_rows = 0 BREAK;

        BEGIN TRANSACTION;

        INSERT INTO fact.match_timeline (match_id)
        SELECT match_id FROM #batch;

        -- info.frames[] is one frame per minute; each frame has an events[] array in time order.
        -- participantId 0 is the game itself (e.g. items granted at the start) and is skipped.
        INSERT INTO fact.item_event (match_id, event_seq, participant_id, timestamp_ms, event_type, item_id)
        SELECT b.match_id,
               CAST(f.[key] AS INT) * 10000 + CAST(e.[key] AS INT),
               ev.participantId,
               ev.[timestamp],
               ev.[type],
               IIF(ev.[type] = 'ITEM_UNDO', ev.beforeId, ev.itemId)
        FROM #batch AS b
        CROSS APPLY OPENJSON(b.payload, '$.info.frames') AS f
        CROSS APPLY OPENJSON(f.value, '$.events') AS e
        CROSS APPLY OPENJSON(e.value) WITH (
            [type]         VARCHAR(40),
            participantId  TINYINT,
            [timestamp]    INT,
            itemId         INT,
            beforeId       INT
        ) AS ev
        WHERE ev.[type] IN ('ITEM_PURCHASED', 'ITEM_SOLD', 'ITEM_UNDO')
          AND ev.participantId BETWEEN 1 AND 10
          -- An undo with beforeId 0 reverts a sale rather than a purchase; purchases are what we count.
          AND IIF(ev.[type] = 'ITEM_UNDO', ev.beforeId, ev.itemId) > 0;

        COMMIT TRANSACTION;

        SET @total_rows += @batch_rows;
    END;

    SELECT @total_rows AS timelines_loaded;
END;
GO
