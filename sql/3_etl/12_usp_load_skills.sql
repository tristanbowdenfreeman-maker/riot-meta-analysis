-- Raw timelines -> fact.participant_skills, for timelines already in fact.match_timeline. Separate from
-- usp_load_timelines so timelines loaded before skills were tracked get backfilled the same way.
-- One run at a time: a second caller (the collector's transform during a backfill) skips instead
-- of loading the same timelines twice.
CREATE OR ALTER PROCEDURE etl.usp_load_skills
    @batch_size INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch_rows INT, @total_rows INT = 0, @lock INT;

    EXEC @lock = sp_getapplock @Resource = N'etl.usp_load_skills', @LockMode = 'Exclusive',
                               @LockOwner = 'Session', @LockTimeout = 0;
    IF @lock < 0
    BEGIN
        SELECT 0 AS timelines_loaded;
        RETURN;
    END;

    CREATE TABLE #ids (match_id VARCHAR(30) NOT NULL PRIMARY KEY);
    CREATE TABLE #skill (
        match_id        VARCHAR(30) NOT NULL,
        participant_id  TINYINT     NOT NULL,
        skill_order     TINYINT     NOT NULL,
        skill_slot      TINYINT     NOT NULL,
        PRIMARY KEY (match_id, participant_id, skill_order)
    );
    CREATE TABLE #batch (
        match_id  VARCHAR(30)   NOT NULL PRIMARY KEY,
        payload   NVARCHAR(MAX) NOT NULL
    );

    WHILE 1 = 1
    BEGIN
        TRUNCATE TABLE #batch;
        TRUNCATE TABLE #skill;

        -- IDs first, then decompress only those (see usp_load_frames).
        TRUNCATE TABLE #ids;
        INSERT INTO #ids (match_id)
        SELECT TOP (@batch_size) t.match_id
        FROM fact.match_timeline AS t
        WHERE NOT EXISTS (SELECT 1 FROM fact.participant_skills AS s WHERE s.match_id = t.match_id)
        ORDER BY t.match_id;

        INSERT INTO #batch (match_id, payload)
        SELECT i.match_id, CAST(DECOMPRESS(r.payload_gz) AS NVARCHAR(MAX))
        FROM #ids AS i
        JOIN stg.timeline_raw AS r ON r.match_id = i.match_id
        WHERE r.status = 'done';

        SET @batch_rows = @@ROWCOUNT;
        IF @batch_rows = 0 BREAK;

        -- SKILL_LEVEL_UP events: {"type": "SKILL_LEVEL_UP", "participantId": 3, "skillSlot": 1, "levelUpType": "NORMAL", ...}
        INSERT INTO #skill (match_id, participant_id, skill_order, skill_slot)
        SELECT b.match_id, ev.participantId,
               ROW_NUMBER() OVER (PARTITION BY b.match_id, ev.participantId
                                  ORDER BY CAST(f.[key] AS INT), CAST(e.[key] AS INT)),
               ev.skillSlot
        FROM #batch AS b
        CROSS APPLY OPENJSON(b.payload, '$.info.frames') AS f
        CROSS APPLY OPENJSON(f.value, '$.events') AS e
        CROSS APPLY OPENJSON(e.value) WITH (
            [type]         VARCHAR(40),
            participantId  TINYINT,
            skillSlot      TINYINT,
            levelUpType    VARCHAR(20)
        ) AS ev
        WHERE ev.[type] = 'SKILL_LEVEL_UP'
          AND ev.levelUpType = 'NORMAL'
          AND ev.participantId BETWEEN 1 AND 10
          AND ev.skillSlot BETWEEN 1 AND 4;

        IF @@ROWCOUNT = 0 BREAK;

        WITH basic AS (
            SELECT match_id, participant_id, skill_slot, COUNT(*) AS points, MAX(skill_order) AS last_point
            FROM #skill
            WHERE skill_order <= 11 AND skill_slot <= 3
            GROUP BY match_id, participant_id, skill_slot
        ),
        priority AS (
            SELECT match_id, participant_id,
                   STRING_AGG(CAST(skill_slot AS CHAR(1)), '') WITHIN GROUP (ORDER BY points DESC, last_point) AS max_order
            FROM basic
            GROUP BY match_id, participant_id
        ),
        sequence AS (
            SELECT match_id, participant_id, MAX(skill_order) AS level_ups,
                   STRING_AGG(CAST(skill_slot AS CHAR(1)), '') WITHIN GROUP (ORDER BY skill_order) AS skill_levels
            FROM #skill
            WHERE skill_order <= 18
            GROUP BY match_id, participant_id
        )
        INSERT INTO fact.participant_skills (match_id, participant_id, skill_levels, skill_start, max_order)
        SELECT q.match_id, q.participant_id, q.skill_levels, LEFT(q.skill_levels, 3),
               IIF(q.level_ups >= 11, p.max_order, NULL)
        FROM sequence AS q
        LEFT JOIN priority AS p ON p.match_id = q.match_id AND p.participant_id = q.participant_id;

        SET @total_rows += @batch_rows;
    END;

    EXEC sp_releaseapplock @Resource = N'etl.usp_load_skills', @LockOwner = 'Session';
    SELECT @total_rows AS timelines_loaded;
END;
GO
