-- Puts the collecting patch live once it has @match_cap valid matches, then deletes the old
-- patch's data. Until then the website keeps showing the old patch. Safe to run every round:
-- it does nothing until the new patch is full, and it finishes any deletion a stopped run left.
CREATE OR ALTER PROCEDURE etl.usp_promote_patch
    @match_cap INT = 30000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @patch VARCHAR(10) =
        (SELECT patch FROM etl.v_patch_progress WHERE status = 'collecting' AND matches >= @match_cap);
    DECLARE @matches_deleted INT = 0;

    IF @patch IS NOT NULL
    BEGIN
        BEGIN TRANSACTION;
        UPDATE etl.patch SET status = 'retired' WHERE status = 'live';
        UPDATE etl.patch SET status = 'live', live_since_utc = SYSUTCDATETIME() WHERE patch = @patch;
        COMMIT TRANSACTION;
    END;

    EXEC etl.usp_delete_retired_patches @matches_deleted = @matches_deleted OUTPUT;

    SELECT @patch AS promoted_patch, @matches_deleted AS matches_deleted;
END;
GO
