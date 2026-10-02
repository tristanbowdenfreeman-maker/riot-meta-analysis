-- Deletes every match of a retired patch: fact tables, raw JSON and the download queue. Works
-- 1,000 matches at a time so each transaction (and the log) stays small, and can be stopped and
-- re-run: a patch's row is only removed once all its matches are gone.
CREATE OR ALTER PROCEDURE etl.usp_delete_retired_patches
    @batch_size      INT = 1000,
    @matches_deleted INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @matches_deleted = 0;
    CREATE TABLE #batch (match_id VARCHAR(30) NOT NULL PRIMARY KEY);

    WHILE 1 = 1
    BEGIN
        TRUNCATE TABLE #batch;
        INSERT INTO #batch (match_id)
        SELECT TOP (@batch_size) m.match_id
        FROM fact.match AS m
        JOIN etl.patch AS p ON p.patch = m.patch
        WHERE p.status = 'retired';

        IF @@ROWCOUNT = 0 BREAK;

        BEGIN TRANSACTION;
        -- Children first, because of the foreign keys.
        DELETE t FROM fact.participant_frame  AS t JOIN #batch AS b ON b.match_id = t.match_id;
        DELETE t FROM fact.team_objective     AS t JOIN #batch AS b ON b.match_id = t.match_id;
        DELETE t FROM fact.item_event         AS t JOIN #batch AS b ON b.match_id = t.match_id;
        DELETE t FROM fact.match_timeline     AS t JOIN #batch AS b ON b.match_id = t.match_id;
        DELETE t FROM fact.participant_rune   AS t JOIN #batch AS b ON b.match_id = t.match_id;
        DELETE t FROM fact.participant_item   AS t JOIN #batch AS b ON b.match_id = t.match_id;
        DELETE t FROM fact.match_ban          AS t JOIN #batch AS b ON b.match_id = t.match_id;
        DELETE t FROM fact.match_participant  AS t JOIN #batch AS b ON b.match_id = t.match_id;
        DELETE t FROM fact.match              AS t JOIN #batch AS b ON b.match_id = t.match_id;
        DELETE t FROM stg.timeline_raw        AS t JOIN #batch AS b ON b.match_id = t.match_id;
        DELETE t FROM stg.match_raw           AS t JOIN #batch AS b ON b.match_id = t.match_id;
        DELETE t FROM stg.match_queue         AS t JOIN #batch AS b ON b.match_id = t.match_id;
        COMMIT TRANSACTION;

        SET @matches_deleted += (SELECT COUNT(*) FROM #batch);
    END;

    DELETE FROM etl.patch WHERE status = 'retired';
END;
GO
