-- Raw matches -> fact.team_objective, for matches already in fact.match. Separate from
-- usp_load_matches so matches loaded before this table existed are filled in too.
CREATE OR ALTER PROCEDURE etl.usp_load_objectives
    @batch_size INT = 1000
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
        FROM stg.v_match_raw AS r
        WHERE EXISTS (SELECT 1 FROM fact.match AS m WHERE m.match_id = r.match_id)
          AND NOT EXISTS (SELECT 1 FROM fact.team_objective AS o WHERE o.match_id = r.match_id)
        ORDER BY r.match_id;

        SET @batch_rows = @@ROWCOUNT;
        IF @batch_rows = 0 BREAK;

        -- info.teams[].objectives: {"baron": {"first": true, "kills": 1}, "dragon": {...}, ...}
        INSERT INTO fact.team_objective (match_id, team_id, objective, is_first, kills)
        SELECT b.match_id, t.teamId, o.[key], ob.[first], ob.kills
        FROM #batch AS b
        CROSS APPLY OPENJSON(b.payload, '$.info.teams') WITH (teamId SMALLINT, objectives NVARCHAR(MAX) AS JSON) AS t
        CROSS APPLY OPENJSON(t.objectives) AS o
        CROSS APPLY OPENJSON(o.value) WITH ([first] BIT, kills SMALLINT) AS ob;

        -- A batch with no objectives at all would be picked again forever, so stop.
        IF @@ROWCOUNT = 0 BREAK;
        SET @total_rows += @batch_rows;
    END;

    SELECT @total_rows AS matches_loaded;
END;
GO
