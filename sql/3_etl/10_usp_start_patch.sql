-- Starts collecting a new patch. `python -m riot_meta patch` calls this when Data Dragon lists a
-- patch that isn't in etl.patch yet.
--   * The live patch stays live (and on the website) until the new one has a full sample.
--   * A patch still collecting is retired and deleted: it never reached a full sample.
--   * Downloads still pending are cancelled, as they are games from the old patch.
--   * Every player is marked unvisited, so their games on the new patch get queued.
-- With no live patch yet (a new database), the new patch goes live straight away.
CREATE OR ALTER PROCEDURE etl.usp_start_patch
    @patch VARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @matches_deleted INT = 0;

    IF NOT EXISTS (SELECT 1 FROM etl.patch WHERE patch = @patch)
    BEGIN
        BEGIN TRANSACTION;
        UPDATE etl.patch SET status = 'retired' WHERE status = 'collecting';
        DELETE FROM stg.match_queue WHERE status = 'pending';
        UPDATE stg.player SET match_ids_fetched_at = NULL;

        INSERT INTO etl.patch (patch, status, started_utc, live_since_utc)
        SELECT @patch,
               CASE WHEN EXISTS (SELECT 1 FROM etl.patch WHERE status = 'live') THEN 'collecting' ELSE 'live' END,
               SYSUTCDATETIME(),
               CASE WHEN EXISTS (SELECT 1 FROM etl.patch WHERE status = 'live') THEN NULL ELSE SYSUTCDATETIME() END;
        COMMIT TRANSACTION;

        EXEC etl.usp_delete_retired_patches @matches_deleted = @matches_deleted OUTPUT;
    END;

    SELECT @matches_deleted AS matches_deleted;
END;
GO
